# Release checklist

A concise, repeatable checklist for cutting a Kallilex release. Work through
the sections in order; do not publish a release until every gate passes.

## 1. Release-candidate gates

- [ ] CI is green on `main` (typecheck/lint, frontend tests, clippy, Rust
      tests, and `tauri build` all pass).
- [ ] Manual app matrix (section 2) has been run and passes.
- [ ] README accuracy check: README describes only shipped behavior, contains
      no contradictions (e.g. no diff-view claims), and any version
      references match the release being cut.

## 2. Manual app matrix

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

## 3. Clean-Mac smoke run

Run this on a Mac (or a fresh user account) that has never run Kallilex:

- [ ] Download the release zip and unzip it.
- [ ] Move `Kallilex.app` to `/Applications`.
- [ ] First launch is blocked by Gatekeeper (app is ad-hoc signed, not
      notarized).
- [ ] Open **System Settings → Privacy & Security**, scroll down, click
      **"Open Anyway"**.
- [ ] The app launches.
- [ ] On first capture, grant the requested **Accessibility** permission.
- [ ] Full workflow works: select text → ⌥⌘K → run an action → Replace puts
      the result back into the source app.

## 4. Shipping steps

1. [ ] Bump `version` in `package.json`, `src-tauri/tauri.conf.json`, and
       `src-tauri/Cargo.toml` — keep all three in sync.
2. [ ] Commit the version bump.
3. [ ] Tag the commit `vX.Y.Z`.
4. [ ] Push the tag.
5. [ ] Wait for the `Release` GitHub Actions workflow to build the universal
       app and attach the zip to a draft release.
6. [ ] Run the gates in sections 1–3 above against the built release.
7. [ ] Publish the draft release.

## 5. Privacy check

- [ ] Confirm no telemetry/analytics code or dependency has been added.
- [ ] Confirm any logs the app produces (if present) contain no selection
      content or other user text.
