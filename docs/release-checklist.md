# Release checklist

A concise, repeatable checklist for cutting a Kallilex release. Work through
the sections in order; do not publish a release until every gate passes.

## 1. Release-candidate gates

- [ ] CI is green on `main` (typecheck/lint, frontend tests, clippy, Rust
      tests, and `tauri build` all pass).
- [ ] Manual app matrix (sections 2, 3, and 4) has been run and passes.
- [ ] README accuracy check: README describes only shipped behavior, contains
      no contradictions (e.g. no diff-view claims), and any version
      references match the release being cut.
- [ ] Platform accuracy check: README and website describe only shipped
      behavior on all three platforms (macOS, Linux, Windows) — no macOS-only
      claim reads as universal, no Linux capability is promised beyond what
      the matrix below confirmed, no Windows capability is promised beyond
      what the matrix confirmed, and none names an install channel that does
      not exist yet.
- [ ] Update path verified: the previous published release on the same
      channel updates in place to this build via Settings → Updates on
      macOS, Windows, and the AppImage; `.deb`/`.rpm` installs show the
      new version with the release-page path and no install button; and
      after the macOS update the Accessibility grant is still present and
      no new Gatekeeper approval was needed. (The first release that carries
      the updater cannot be updated *into*; for it, run this gate from it to
      the following pre-release instead.)

## 2. macOS app matrix

For each app: select some text, trigger capture (default ⌥⌘K), confirm the
popover shows the captured text, run a spell check and/or AI action, then use
Replace and confirm the result lands back in the source app and the original
clipboard contents are restored afterwards.

| App | Automatic capture (⌥⌘K) | Edit / spell check | Replace puts result back | Clipboard restored after |
| --- | --- | --- | --- | --- |
| TextEdit | [ ] | [ ] | [ ] | [ ] |
| Notes | [ ] | [ ] | [ ] | [ ] |
| Mail | [ ] | [ ] | [ ] | [ ] |
| Safari | [ ] | [ ] | [ ] | [ ] |
| Chrome | [ ] | [ ] | [ ] | [ ] |
| VS Code | [ ] | [ ] | [ ] | [ ] |
| Terminal | [ ] | [ ] | [ ] | [ ] |
| Slack | [ ] | [ ] | [ ] | [ ] |

Password / secure field (e.g. a macOS password field or a browser password
input): expected behavior is that capture fails or falls back gracefully,
Kallilex does not crash, and no secret is left on the clipboard afterwards.

- [ ] Password/secure field checked — capture fails or falls back gracefully,
      no crash, no secret leaked to the clipboard afterwards.

Keyboard shortcuts:

- [ ] Full workflow without the mouse: global shortcut (⌥⌘K) → edit text →
      ⌘1 (or another saved prompt) → ⌘↩ (Replace) puts the result back;
      ⌘⇧C (Copy) copies the result; ⌘L opens the custom field with cursor in
      it and ↩ runs it; holding ⌘ shows the badges; recording, take-over and
      reset in Settings → Shortcuts work.
- [ ] On a German layout, ⌥L still types @ in the popover, and Z/Y show the
      printed labels in Settings → Shortcuts.

## 3. Linux manual matrix

Verify portal support per compositor. For each environment, launch the app and
confirm the listed capabilities work as specified; the app should report which
portals are active in Settings → Accessibility.

- [ ] X11 regression pass: shortcut → capture → replace → clipboard restored
      (existing tier-1 behavior).
- [ ] GNOME 48+ Wayland full round-trip: global shortcut triggers capture;
      Replace types the result back into the source app; original clipboard
      restored; the RemoteDesktop permission dialog appears exactly once across
      app restarts (restore token works).
- [ ] KDE Plasma 6 Wayland full round-trip: same as GNOME, plus the portal's
      shortcut-bind dialog appears on first launch and the binding survives an
      app restart (portal identifies the app id correctly).
- [ ] Hyprland: global shortcut works; Replace is absent/copy-only; the notice
      names the missing RemoteDesktop portal.
- [ ] Sway (wlroots): degraded-mode regression — tray capture works,
      copy-only, notice names both missing portals; no permission dialogs ever
      appear.
- [ ] Token revocation: revoke Kallilex's remote-desktop permission in system
      settings → the next Replace re-prompts exactly once, then works.
- [ ] Popover keyboard focus on GNOME and KDE Wayland: when the popover opens
      it actually has keyboard focus (type immediately). (This is a known
      verification point for tao/xdg-activation.)
- [ ] No-portal environment: with xdg-desktop-portal absent, Kallilex reports
      no Wayland capabilities (degraded mode) rather than pretending.
- [ ] App id on Wayland: from an *installed* package, launching Kallilex from a
      terminal (not the app menu) still binds the global shortcut — the package
      ships `com.webcommits.kallilex.desktop`, which is what lets the portal
      resolve the app id it requires. An uninstalled dev run (`pnpm tauri dev`)
      has no app id and logs "An app id is required"; that is expected, not a
      release blocker.
- [ ] Input-synthesis opt-out: on a portal-capable Wayland compositor
      (GNOME/KDE), turn "Use automatic paste-back" off in Settings → General
      *before* the first Replace — the remote-desktop permission dialog never
      appears, capture still works from the current selection, Copy still
      works, Replace is absent, and the popover shows no notice claiming a
      missing portal.
- [ ] Auto-copy: with "Copy the result automatically" on, both a successful AI
      action and an applied spellcheck suggestion leave the result on the
      clipboard ready to paste, without clicking Copy.
- [ ] AppImage on Wayland: run the AppImage (not an installed package) on a
      portal-capable compositor and confirm the documented consequence — the
      global shortcut does **not** bind (the log names the missing app id),
      while opening Kallilex from the tray still captures the primary
      selection. An AppImage installs no desktop entry, so the portal cannot
      resolve the app id; the README says so at the install list. If the
      shortcut *does* bind, that README caveat is wrong and must be corrected
      before publishing.

Keyboard shortcuts:

- [ ] Full workflow without the mouse on X11: global shortcut (Ctrl+Alt+K) →
      edit text → Ctrl+1 (or another saved prompt) → Ctrl+Enter (Replace) puts
      the result back; Ctrl+Shift+C (Copy) copies the result; Ctrl+L opens the
      custom field with cursor in it and ↩ runs it; holding Ctrl shows the
      badges; recording, take-over and reset in Settings → Shortcuts work.
- [ ] Same flow on one Wayland compositor (GNOME or KDE).
- [ ] On Wayland, the global shortcut row in Settings → Shortcuts stays
      read-only (portal manages it).
- [ ] A Ctrl+Alt+F-key shows the warning in Settings → Shortcuts.

## 4. Windows manual matrix

For each app: select some text, trigger capture (default Ctrl+Alt+K), confirm
the popover shows the captured text, run a spell check and/or AI action, then
use Replace and confirm the result lands back in the source app and the
original clipboard contents are restored afterwards.

| App | Automatic capture (Ctrl+Alt+K) | Edit / spell check | Replace puts result back | Clipboard restored after |
| --- | --- | --- | --- | --- |
| Notepad | [ ] | [ ] | [ ] | [ ] |
| Word | [ ] | [ ] | [ ] | [ ] |
| Outlook | [ ] | [ ] | [ ] | [ ] |
| Edge | [ ] | [ ] | [ ] | [ ] |
| Chrome | [ ] | [ ] | [ ] | [ ] |
| VS Code | [ ] | [ ] | [ ] | [ ] |
| Windows Terminal | [ ] | [ ] | [ ] | [ ] |
| Slack | [ ] | [ ] | [ ] | [ ] |

Password / secure field (e.g. a Windows credential prompt or a browser
password input): expected behavior is that capture fails or falls back
gracefully, Kallilex does not crash, and no secret is left on the clipboard
afterwards.

- [ ] Password/secure field checked — capture fails or falls back gracefully,
      no crash, no secret leaked to the clipboard afterwards.
- [ ] Elevated app (e.g. Registry Editor run as administrator): capture
      reports no selection and Replace reports a clear error, rather than
      silently doing nothing or crashing — this is the expected UIPI
      limitation, not a bug.
- [ ] Tray icon is legible on both a light and a dark taskbar.
- [ ] The installer installs per-user with no admin prompt, and the app
      starts from the Start menu.
- [ ] The autostart toggle in Settings survives a reboot.
- [ ] Spell check uses the installed display language(s); with no
      spell-check feature installed for any of them, the backend rejects the
      check with a named error instead of returning an empty result (today
      the popover only logs that error to the console — known, pre-existing
      on every platform — so verify it in the dev tools rather than
      expecting a visible message).

Keyboard shortcuts:

- [ ] Full workflow without the mouse: global shortcut (Ctrl+Alt+K) → edit
      text → Ctrl+1 (or another saved prompt) → Ctrl+Enter (Replace) puts the
      result back; Ctrl+Shift+C (Copy) copies the result; Ctrl+L opens the
      custom field with cursor in it and ↩ runs it; holding Ctrl shows the
      badges; recording, take-over and reset in Settings → Shortcuts work.
- [ ] On a German layout with AltGr, AltGr+Q still types @ in the popover.
- [ ] Ctrl+Alt+K can be recorded as the global shortcut in Settings →
      Shortcuts.

## 5. Clean-install smoke runs

### 5a. Clean Mac

Run this on a Mac (or a fresh user account) that has never run Kallilex:

- [ ] Download the release zip and unzip it.
- [ ] Move `Kallilex.app` to `/Applications`.
- [ ] First launch is blocked by Gatekeeper (app is self-signed, not
      notarized).
- [ ] Open **System Settings → Privacy & Security**, scroll down, click
      **"Open Anyway"**.
- [ ] The app launches.
- [ ] On first capture, grant the requested **Accessibility** permission.
- [ ] The Accessibility permission survives an app restart: quit Kallilex,
      relaunch it, and confirm the checkbox in System Settings →
      Accessibility is still present and enabled and the app does not
      re-prompt. (This regresses if the release was not signed with the
      stable release certificate — see section 8.)
- [ ] Full workflow works: select text → ⌥⌘K → run an action → Replace puts
      the result back into the source app.
- [ ] Onboarding's last step ("You're all set") mentions popover shortcuts
      (shows that ⌘1 runs the first prompt, ⌘↩ replaces, ⌘⇧C copies, and ⌘
      held shows all shortcuts).

### 5b. Clean Linux machine

Run this on a machine (or fresh user account) that has never run Kallilex:

- [ ] Install the release `.deb`: `sudo apt install ./Kallilex-*.deb`.
- [ ] The tray icon appears (on GNOME this needs
      `gnome-shell-extension-appindicator`; its absence is the extension
      missing, not the app failing).
- [ ] First capture works: select text → Ctrl+Alt+K → the popover shows it.
- [ ] Spell check resolves a dictionary with **no** system Hunspell
      dictionary installed — the bundled `en_US`/`de_DE` fallback is found.
- [ ] Settings → Accessibility reports this session's real capabilities
      (session type and, on Wayland, which portals are live) rather than a
      default or a guess.
- [ ] An API key saved in Settings survives an app restart (Secret Service is
      reachable), and no key appears anywhere under `~/.config`.

### 5c. Clean Windows machine

Run this on a machine (or fresh user account) that has never run Kallilex:

- [ ] Download `Kallilex-vX.Y.Z-windows-x86_64-setup.exe` and run it.
- [ ] SmartScreen shows "Windows protected your PC" — click through with
      **More info → Run anyway**.
- [ ] The installer completes per-user, with no admin prompt.
- [ ] The tray icon appears in the notification area.
- [ ] First capture works: select text → Ctrl+Alt+K → the popover shows it.
- [ ] Spell check flags a misspelling in an installed display language.
- [ ] An API key saved in Settings survives an app restart (Credential
      Manager is reachable), and no key appears anywhere under `%APPDATA%`.

## 6. Shipping steps

1. [ ] Bump `version` in `package.json`, `src-tauri/tauri.conf.json`, and
       `src-tauri/Cargo.toml` — keep all three in sync, and let
       `src-tauri/Cargo.lock` follow (a `cargo check` refreshes it).
2. [ ] Commit the version bump.
3. [ ] Tag the commit `vX.Y.Z`. A pre-release carries a semver suffix
       (`v0.6.0-beta.1`); the workflow flags it *Pre-release* on GitHub
       automatically, the app's Stable channel ignores it, and the website
       keeps pointing at the newest non-pre-release. The workflow refuses to
       build when the tag does not match the version in the three files.
4. [ ] Push the tag.
5. [ ] Wait for the `Release` GitHub Actions workflow: three build jobs
       (macOS, Linux, Windows) and a fourth, `publish-update-manifest`,
       which assembles `latest.json` from the uploaded signatures.
6. [ ] Confirm the draft release carries the macOS artifacts — the zip,
       `Kallilex-vX.Y.Z-macos-universal.app.tar.gz`, and its `.sig`.
7. [ ] Confirm the draft release carries the Linux artifacts — `.deb`,
       `.rpm`, and `.AppImage` plus one `.sha256` file each, and
       `Kallilex-vX.Y.Z-linux-x86_64.AppImage.sig` (deb/rpm `.sig` files
       may be present too) — and that every filename carries the tag being
       cut.
8. [ ] Confirm the draft release carries the Windows artifacts —
       `Kallilex-vX.Y.Z-windows-x86_64-setup.exe` plus its `.sha256` and
       `.sig` files — with the same tag in the filename.
9. [ ] Confirm `latest.json` is attached and lists exactly four platforms:
       `darwin-aarch64`, `darwin-x86_64`, `linux-x86_64`, `windows-x86_64`,
       each with a `url` under `releases/download/vX.Y.Z/` and a
       `signature`. One `.sig` per installable artifact must exist; a
       platform missing from the manifest would show as "available, not
       installable" to those users for as long as the release is current.
10. [ ] Run the gates in sections 1–5 above against the built release. A
        draft is invisible to the app — only publishing makes the update
        reachable — so the update-path gate in section 1 is run against the
        published release of the previous version, not against this draft.
11. [ ] Publish the draft release. Afterwards, `curl -sI` on each `url` in
        `latest.json` answers with a redirect to GitHub's download storage,
        and a check from the previous version offers this one.
12. [ ] For a stable release, confirm the `Homebrew` workflow ran on
        publishing and that `LStoneyy/homebrew-tap` has a `kallilex X.Y.Z`
        commit with the new version and checksum. Pre-releases are skipped by
        design. If the run failed, fix the cause and re-run it with
        `gh workflow run homebrew.yml -f tag=vX.Y.Z`.

Unpublishing or deleting a published release removes it from every future
check immediately: the app compares versions on each check and remembers no
offers, so a bad build costs at most one check for whoever ran one during
the window, and nothing else.

## 7. Privacy check

- [ ] Confirm no telemetry/analytics code or dependency has been added.
- [ ] Confirm any logs the app produces (if present) contain no selection
      content or other user text.
- [ ] Confirm the update check still sends nothing but the release-list
      request to `api.github.com` (no identifiers, no settings), and that
      with the frequency set to *Never* the app makes no request on its own.

## 8. macOS release signing

Release builds are signed with a **stable self-signed certificate** ("Kallilex
Signing") instead of an ad-hoc signature. macOS ties TCC grants (Accessibility)
to the app's code-signing identity; with ad-hoc signing that identity is the
cdhash of the exact binary, so every release invalidated the user's grant and
left a stale, un-fixable entry in System Settings. With the stable certificate
the designated requirement pins the certificate leaf, and the grant survives
updates. Gatekeeper behavior is unchanged (the app is still not notarized).

How it is wired up:

- The public certificate lives in the repo at
  `src-tauri/packaging/macos/kallilex-signing-cert.pem`.
- The private key + certificate (`.p12`, legacy PKCS#12 format — required for
  `security import`) and its password live in the GitHub Actions secrets
  `APPLE_CERTIFICATE` (base64 of the `.p12`) and
  `APPLE_CERTIFICATE_PASSWORD`. The originals are kept locally in
  `~/.kallilex-signing/` on the release manager's machine.
- The release workflow imports the certificate into a CI keychain, trusts it
  (`sudo security add-trusted-cert`, required for self-signed identities),
  builds with `--config src-tauri/tauri.macos-release.conf.json` (which sets
  `signingIdentity` to "Kallilex Signing"), and then **verifies** that the
  built app's designated requirement pins the repo certificate — the job
  fails if it does not.
- Local dev builds stay ad-hoc (`"signingIdentity": "-"` in
  `tauri.conf.json`); no certificate is needed to develop.

Testing the signing setup without cutting a release: run the `Release`
workflow manually (`workflow_dispatch`); it builds and verifies the signed
macOS app and uploads it as a workflow artifact instead of creating a release.

Rotating the certificate (only if the key is lost or compromised): generate a
new key + certificate with the same CN, export the `.p12` with
`openssl pkcs12 -export -legacy`, update both secrets and the `.pem` in the
repo. Note: rotation changes the signing identity, so every user's
Accessibility grant is invalidated once — users must
`tccutil reset Accessibility com.webcommits.kallilex` and re-grant (the README
documents this).

## 9. Update signing key

In-app updates are verified with a minisign key pair created with
`pnpm tauri signer generate`. The app installs a download only when its
signature matches the public key compiled into the app; anything else is
discarded before it is installed.

How it is wired up:

- The **public key** lives in the repo in `src-tauri/tauri.conf.json` under
  `plugins.updater.pubkey`.
- The **private key** and its **password** live in the GitHub Actions
  secrets `TAURI_SIGNING_PRIVATE_KEY` (the content of the key file) and
  `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`. The originals are kept locally in
  `~/.kallilex-signing/` on the release manager's machine, next to the
  Apple certificate. Neither is ever committed or printed in a workflow log.
  Set the key secret straight from the file
  (`gh secret set TAURI_SIGNING_PRIVATE_KEY < ~/.kallilex-signing/updater.key`)
  rather than by copying terminal output: zsh appends a `%` to output that
  ends without a newline, and the build then fails with "failed to decode
  base64 secret key" after signing the app.
- The release workflow passes both secrets as environment variables to the
  three `tauri build` steps only, together with the overlay
  `src-tauri/tauri.release.conf.json`, which turns on updater artifacts.
  `tauri build` then writes one `.sig` next to each installable artifact,
  the build jobs upload them, and the `publish-update-manifest` job
  assembles `latest.json` from them.
- The overlay is not part of `tauri.conf.json` on purpose: with updater
  artifacts enabled, `tauri build` fails when the private key is absent.
  Plain `pnpm tauri build` (CI and local development) stays unsigned and
  needs no key.

Testing the signing setup without cutting a release: run the `Release`
workflow manually (`workflow_dispatch`); it builds all three platforms with
signing enabled and uploads the bundles, including the `.sig` files, as
workflow artifacts instead of creating a release.

Rotating the key is **not** a normal operation. The public key is baked into
every installed app, so a new key pair means every existing install rejects
every future update and must be reinstalled by hand once. Rotate only if
the private key is lost or compromised — losing it has the same effect,
because no further release can be signed for the existing installs — and
announce the rotation in the README and the release notes when you do.

## 10. Homebrew tap

The cask lives in
[LStoneyy/homebrew-tap](https://github.com/LStoneyy/homebrew-tap) as
`Casks/kallilex.rb`. Users install it with `brew install --cask
lstoneyy/tap/kallilex`.

- The `Homebrew` workflow (`.github/workflows/homebrew.yml`) runs when a
  release is published, skips pre-releases and any tag that is not `vX.Y.Z`,
  downloads `Kallilex-vX.Y.Z-macos-universal.zip`, and lets
  `scripts/bump-homebrew-cask.sh` rewrite `version` and `sha256`. The script
  refuses downgrades and a changed checksum for a version the tap already
  has; a re-run for the current version ends without a commit.
- It pushes with the secret `HOMEBREW_TAP_TOKEN`: a fine-grained personal
  access token limited to the tap repository with *Contents: Read and
  write*. **It expires on 2027-10-26.** Before then, create a new token with
  the same scope and set it from a file: `gh secret set HOMEBREW_TAP_TOKEN
  -R LStoneyy/kallilex < token-file`, then delete the file. An expired token
  shows up as a failed "Checkout the tap" step.
- The cask is not notarized and stays in the user's quarantine: the first
  launch needs "Open Anyway", like the zip. Homebrew carries that approval
  over to later upgrades as long as the signing certificate stays the same
  (section 8). Do not add a `postflight` that strips the quarantine
  attribute.
- The cask sets `auto_updates true`; the in-app updater stays the primary
  update path. Brew users who want Homebrew to update it anyway use `brew
  upgrade --greedy`.
