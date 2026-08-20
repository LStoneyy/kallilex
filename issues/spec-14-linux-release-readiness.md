# Spec 14 — Linux release readiness: truthful docs, a cross-platform site, v0.3.0

Status: ready-for-agent
Phase: release preparation (closes out the Linux port shipped by specs 11–13;
no application behavior changes)
Depends on: spec-11, spec-12, spec-13 (the Linux/Wayland behavior this spec
describes must already be true), and spec-10 (the website structure and its
JSON-LD conventions this spec extends). The Windows port stays at spec-15+.

## Problem Statement

Specs 11–13 shipped the Linux port: X11 as tier 1, portal-backed Wayland on
GNOME/KDE, an honest degraded mode elsewhere, packaging as `.deb`/`.rpm`/
AppImage, and a CI/release matrix that builds and uploads all three. The code
is done and green — typecheck, frontend tests, clippy, Rust tests, and a full
`tauri build` producing all three Linux bundles all pass.

What is not done is everything *around* the code, and every item of it is a
statement to a user that is currently false or missing:

1. **The version is still 0.2.0, and `v0.2.0` is already tagged.** Twenty-four
   commits — the entire Linux port — sit behind that tag. Nothing can be
   released until the three version files move.
2. **The README still describes a macOS-only product in the places that
   matter.** "Later" lists "Linux and Windows builds" as unbuilt; the spell
   checking section says a future Linux build "can plug in another local
   checker" when Linux has shipped one; two places claim API keys live in the
   macOS Keychain without mentioning the Secret Service; the capture section
   documents only the macOS paths.
3. **The website is entirely macOS.** Title, meta description, OG/Twitter
   cards, the `SoftwareApplication` JSON-LD's `operatingSystem`, both download
   buttons, the requirements line, two feature cards, and two FAQ answers all
   say macOS and only macOS. There is no Linux download at all, and
   `main.js` resolves exactly one release asset pattern — the macOS zip. After
   spec-10 made the site the project's front door, shipping a Linux release
   behind a macOS-only page means the release is invisible to the people it
   was built for.
4. **The AppImage cannot bind the global shortcut on Wayland, and nothing says
   so.** `wayland::register_app_id` requires the portal to resolve
   `<bundle identifier>.desktop` in the *installed* desktop database — that is
   exactly why commit `f330833` ships `com.webcommits.kallilex.desktop` in the
   packages. The mapping exists under `bundle.linux.deb.files` and
   `bundle.linux.rpm.files` only, and the built `Kallilex.AppDir` contains just
   `Kallilex.desktop`; an AppImage installs nothing into the desktop database
   in the first place, so no placement inside the image can fix it. The README
   nevertheless offers the AppImage as an equal third option directly under a
   paragraph promising GNOME/KDE Wayland users "the full loop".
5. **The release checklist has no gate for either.** Its Linux matrix covers
   installed packages only, and its clean-install smoke run is Mac-only.

None of this is code. All of it is what a user reads before deciding whether
the thing works on their machine.

## Solution

Four documentation/packaging-metadata slices, no application source changes:

- **A) README truthfulness pass** — every macOS-only claim either gains its
  Linux counterpart or is labelled as macOS-specific, plus the AppImage
  Wayland caveat.
- **B) Cross-platform website** — copy, structured data, an OS-aware download
  button, and a Linux install card with the three artifacts.
- **C) Release checklist** — the gates that would have caught items 2–4,
  plus an AppImage-on-Wayland verification row and a Linux clean-install
  smoke run.
- **D) Version bump to 0.3.0** — the last commit before the tag.

Slice D lands last so the version bump is the final commit before `v0.3.0`.

## User Stories

1. As a Linux user who lands on kallilex.webcommits.info, I want to see that
   Kallilex runs on my system and which package to download, so that I don't
   conclude from the page that it is a Mac-only tool.
2. As a Wayland user choosing between the packages, I want to be told that the
   global shortcut needs the `.deb`/`.rpm` desktop entry, so that I don't pick
   the AppImage and conclude the shortcut is broken.
3. As a reader of the README, I want the spell checking, secret storage, and
   capture sections to state what happens on my platform, so that I never have
   to infer Linux behavior from macOS prose.
4. As the maintainer cutting the next release, I want the checklist to gate the
   claims the docs make, so that a platform ships with its documentation
   instead of after it.
5. As a macOS user, I want the page and README to be no less clear about macOS
   than they are today.

## Implementation Decisions

### Slice A — README truthfulness pass

Scope: `README.md` only. Every edit below is a named, existing passage; do
not restructure the document, add sections beyond those named, or change the
macOS instructions.

- **`## Later` list.** `- Linux and Windows builds;` becomes
  `- Windows build;`. Linux ships in this release.
- **Spell checking section.** The sentence "The core API is abstracted so
  future Linux/Windows builds can plug in another local checker." is now
  false for Linux. Replace it with the shipped truth: the `SpellChecker`
  seam is backed by NSSpellChecker on macOS and by `spellbook` — a pure-Rust
  Hunspell-compatible engine — on Linux, reading system Hunspell/MySpell
  dictionaries with bundled `en_US`/`de_DE` fallbacks; a future Windows build
  plugs into the same seam. Do not duplicate the dictionary-path detail that
  the Linux section already carries; cross-reference it instead.
- **Secret storage.** Both "Keychain-only API keys" (Privacy/principles
  bullet) and the settings bullet "optional API key (stored in the Keychain,
  never in config files)" must name both backends: the macOS Keychain and the
  Linux Secret Service (gnome-keyring / KWallet via the `keyring` crate's
  `sync-secret-service` feature). The invariant that keys never touch a config
  file is unchanged and must stay stated.
- **Native desktop features.** The paragraph beginning "On macOS, selected-text
  capture and replacement live behind a platform abstraction…" gains its Linux
  half. Read `src-tauri/src/platform/linux/` before writing it — state what the
  code does (X11: `x11rb` window query plus key synthesis and activation;
  Wayland: XDG portals for the global shortcut and input synthesis, primary
  selection via `arboard`'s data-control backend, no cross-client window
  query), and invent nothing.
- **Capture section.** Its two bullets describe macOS only. Label them as the
  macOS paths and point to the Linux section for the Linux ones, rather than
  leaving them reading as universal.
- **Linux section, AppImage.** The install list's AppImage line gains the
  caveat, and it must be stated where the choice is made, not in a footnote:
  on Wayland the portal-bound global shortcut requires an installed desktop
  entry whose name matches the bundle identifier, which only the `.deb` and
  `.rpm` provide — so on Wayland prefer those, and expect an AppImage run to
  fall back to opening Kallilex from the tray. On X11 the AppImage is fully
  equivalent. Phrase this as the packaging consequence it is, without
  promising a future fix.

### Slice B — cross-platform website

Scope: `website/index.html`, `website/main.js`, and `website/styles.css` only
if a new element genuinely needs a rule. Keep spec-10's SEO conventions: the
FAQ answers rendered in the page and the copies inside the `FAQPage` JSON-LD
must stay character-identical, and every JSON-LD block must remain valid JSON.

- **Head and cards.** `<title>`, `meta[name=description]`, `og:title`,
  `og:description`, `twitter:title`, and `twitter:description` stop saying
  "the macOS menu bar" and name both platforms — menu bar on macOS, tray on
  Linux. Keep the title under ~60 characters and the descriptions under ~160,
  and keep the three description strings identical to each other, as they are
  today.
- **`SoftwareApplication` JSON-LD.** `"operatingSystem": "macOS"` becomes
  `"macOS, Linux"`, and its `description` stays in sync with the meta
  description.
- **Hero.** The subline matches the new description. The requirements line
  ("macOS · Apple Silicon & Intel (universal)") gains the Linux side: x86_64,
  `.deb` / `.rpm` / AppImage. The shortcut is written as ⌥⌘K with
  `Ctrl+Alt+K` named as the Linux default wherever the chord appears in prose
  or in a `<kbd>` row (hero, demo step, FAQ) — the app already defaults to
  `Ctrl+Alt+K` off macOS.
- **OS-aware download.** The hero and install-card primary buttons keep their
  current no-JS state (label "Download for macOS", href pointing at the
  releases page) and `main.js` upgrades them when it detects Linux: label
  "Download for Linux", href pointing at the `.deb`. Detection must exclude
  Android and ChromeOS, whose user agents also contain "Linux". A user agent
  that is neither macOS nor Linux keeps the untouched default.
- **`loadLatestRelease`.** Today it matches one pattern and gives up otherwise.
  It must resolve the macOS zip and all three Linux artifacts
  (`Kallilex-v*-linux-x86_64.deb` / `.rpm` / `.AppImage`, matching the names
  `release.yml` uploads), wire each into its link, and leave any link whose
  asset is missing pointing at the releases page rather than at a dead URL.
  The existing failure behavior — a draft-only release 404s and the page
  degrades silently — must survive unchanged.
- **Linux install card.** The install section gains a third card next to
  Homebrew and Direct download, with the three package links, the install
  commands (`sudo apt install ./Kallilex-*.deb`, `sudo dnf install
  ./Kallilex-*.rpm`, `chmod +x` for the AppImage) reusing the existing
  `code-block` + copy-button markup, and two short notes: what Wayland support
  depends on (portals; X11 fully supported; Settings → Accessibility shows
  what is live) and the AppImage caveat from Slice A in one sentence. If
  `install__grid` is a fixed two-column grid, extend it minimally rather than
  redesigning the section.
- **Feature cards.** "Offline spell check" must name both engines
  (NSSpellChecker on macOS, Hunspell-compatible on Linux) and drop "Nothing
  ever leaves your Mac" phrasing where it now excludes half the users;
  "Keys in the Keychain" becomes the system-keychain claim covering the
  Secret Service; "Menu-bar native" mentions the Linux tray.
- **FAQ.** The Accessibility-permission answer and the offline-spell-check
  answer each gain one Linux sentence — Linux has no grantable capture
  permission, and Wayland's optional paste-back permission is a portal dialog
  the user can decline (spec-13's opt-out). Update the JSON-LD copies in the
  same edit.
- **Honesty bound.** The page may claim only what specs 11–13 shipped and the
  manual matrix has confirmed: X11 full support, GNOME/KDE Wayland full loop
  via portals, degraded copy-only elsewhere. No claim about Flatpak, AUR,
  aarch64, or auto-updates.

### Slice C — release checklist

Scope: `docs/release-checklist.md` only.

- **§1 gates** gain: README and website describe only shipped behavior on both
  platforms, and name no unshipped install channel.
- **§3 Linux matrix** gains an AppImage-on-Wayland row: run the AppImage on a
  portal-capable compositor and confirm the documented consequence — the
  global shortcut does not bind (the log names the missing app id), the tray
  path still captures, and the README's caveat matches what actually happens.
  If it *does* bind, the README caveat is wrong and must be corrected before
  release.
- **§4** is Mac-only; add a parallel Linux clean-install smoke run: install the
  `.deb` on a machine that has never run Kallilex, confirm the tray icon
  appears (with the AppIndicator note for GNOME), the first capture works, the
  bundled dictionaries resolve when no system Hunspell dictionary is present,
  and Settings → Accessibility reports the session's real capabilities.
- **§5 shipping steps** gain a step between building and publishing: confirm
  the draft release carries all three Linux artifacts and their `.sha256`
  files from the second job, alongside the macOS zip.

### Slice D — version bump to 0.3.0

Scope: `package.json`, `src-tauri/tauri.conf.json`, `src-tauri/Cargo.toml`,
`src-tauri/Cargo.lock`.

- All three declared versions move 0.2.0 → 0.3.0 and must stay identical;
  `Cargo.lock`'s `kallilex` entry follows (a `cargo check` refreshes it).
- 0.3.0, not 0.2.1: a new platform is a minor bump.
- No changelog file exists and none is introduced — release notes are
  generated by `gh release create --generate-notes`.
- Tagging and pushing are **not** part of this spec. The tag is cut by the
  maintainer after the manual matrix passes.

## Testing Decisions

- Slices A and C are documentation-only and change no build input; the full
  check set (`pnpm check`, `pnpm test`, `cargo clippy --all-targets -D
  warnings`, `cargo test`) must nevertheless still pass after them, since it
  is the release gate.
- Slice B has no test harness — the site is static and untested by design.
  Verification is explicit and manual: both JSON-LD blocks parse as JSON, the
  FAQ answers match their JSON-LD copies exactly, the page renders and every
  link resolves with JavaScript disabled, and `loadLatestRelease` handles the
  404-only-a-draft case without throwing.
- After Slice D: `pnpm tauri build` on Linux must still produce all three
  bundles, named 0.3.0, and the `.deb` must still contain both
  `com.webcommits.kallilex.desktop` and `Kallilex.desktop`.
- No test may be added that asserts documentation wording.

## Out of Scope

- Any change to application behavior, Rust sources, or Svelte components.
  If a doc slice cannot be written truthfully without a code change, that is
  an escalation, not a licence to edit the code.
- The Homebrew cask (spec-08, still unimplemented — the site's "coming soon"
  note stays as it is), notarization, and the auto-updater.
- Flatpak, Snap, AUR, Flathub, aarch64 Linux builds, and a Linux auto-updater
  (all explicitly out per spec-11).
- Regenerating `assets/og-card.png`, the demo video, or any other macOS-only
  artwork; replacing them is a design task of its own.
- Running the manual Linux matrix. This spec provides the gates; the
  maintainer runs them.
- Tagging, pushing, or publishing the release.
- The Windows port (spec-15+).

## Further Notes

- The AppImage caveat rests on the documented contract in
  `wayland::register_app_id` — the portal rejects an app id it cannot resolve
  to an installed desktop entry — plus the observation that the built AppDir
  carries only `Kallilex.desktop`. It has not been observed end-to-end on a
  live compositor, which is precisely why Slice C adds it to the matrix rather
  than treating it as settled.
- Dropping the AppImage from the release was considered and rejected: it is
  fully functional on X11 and remains the only zero-install option, so the
  honest fix is a caveat at the point of choice, not removal.
- Slices land as separate tasks A → B → C → D with a review gate between them,
  one commit per slice, matching the spec-11/12/13 workflow.
