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
3. [ ] Tag the commit `vX.Y.Z`.
4. [ ] Push the tag.
5. [ ] Wait for the `Release` GitHub Actions workflow to build the universal
       app and attach the zip to a draft release.
6. [ ] Confirm the draft release carries the Linux artifacts from the second
       job as well — `.deb`, `.rpm`, and `.AppImage` plus one `.sha256` file
       each — alongside the macOS zip, and that every filename carries the
       tag being cut.
7. [ ] Confirm the draft release also carries the Windows artifact from the
       third job — `Kallilex-vX.Y.Z-windows-x86_64-setup.exe` plus its
       `.sha256` file — with the same tag in the filename.
8. [ ] Run the gates in sections 1–5 above against the built release.
9. [ ] Publish the draft release.

## 7. Privacy check

- [ ] Confirm no telemetry/analytics code or dependency has been added.
- [ ] Confirm any logs the app produces (if present) contain no selection
      content or other user text.

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
