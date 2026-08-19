# Spec 02 — Capture: global shortcut, selection capture & fallback

Status: ready-for-agent
Phase: P1 of the Kallilex macOS MVP (source: PRD.md, approved 2026-08-19)
Depends on: spec-01 (scaffold)

## Problem Statement

From the user's perspective: to process text with any tool today, they must manually copy it, switch apps, paste it in, and later paste the result back. The whole point of Kallilex is removing that friction — but that only works if pressing one global shortcut reliably grabs the selected text from whatever application is frontmost, including apps that make their selection hard to reach, and without the macOS Accessibility permission becoming a frustrating dead end.

## Solution

Pressing the global shortcut (default ⌥⌘K) captures the current selection at trigger time. The primary path reads the selection through the macOS Accessibility API. When that fails — terminals, secure fields, some web content — an automatic clipboard fallback copies the selection behind the scenes and restores the clipboard afterwards. A first-run onboarding panel explains the Accessibility permission with a live status indicator and a deep link into System Settings; permission status updates without an app restart. If both capture paths fail, the popover opens with an empty field and a hint so the app stays usable.

## User Stories

1. As a writer, I want to press a single global shortcut while text is selected in any app, so that I can start working on it without copying manually.
2. As a writer, I want the shortcut to work no matter which application is frontmost, so that I don't have to think about where I am.
3. As a writer, I want the captured text to appear in the popover, so that the next step is immediate.
4. As a writer using TextEdit, Notes, or Safari, I want the selection read directly through the Accessibility API, so that capture is instant and my clipboard is untouched.
5. As a writer using Terminal or other apps that don't expose their selection, I want an automatic clipboard-based fallback, so that the shortcut works there too without extra steps.
6. As a writer, I want my previous clipboard content restored after the fallback has run, so that Kallilex never silently destroys what I copied.
7. As a writer, I want the clipboard restored even when I cancel — via Escape or by the popover losing focus — so that aborting is always side-effect free.
8. As a first-time user, I want a panel that explains why the Accessibility permission is needed, so that I can make an informed choice instead of hitting a wall.
9. As a first-time user, I want a live granted/not-granted indicator in that panel, so that I can see the effect of granting without restarting the app.
10. As a first-time user, I want a deep link that opens System Settings directly at Privacy & Security → Accessibility, so that I don't have to hunt through menus.
11. As a user, I want a compact permission prompt with the same deep link at trigger time if permission is missing, so that I immediately understand why capture failed.
12. As a user, I want the source application remembered, so that the result can later be written back to where the text came from.
13. As a user, I want a sensible default shortcut (⌥⌘K), so that everything works out of the box.
14. As a user, I want a clear error when shortcut registration conflicts with the system or another app, so that failures never pass silently.
15. As a user, I want capture to happen before the popover takes focus, so that the selection isn't lost to the focus change.
16. As a user, when both capture paths fail, I want the popover to open with an empty text field and a hint, so that I can still paste or type text manually and use the app.
17. As a user, I want the fallback's clipboard backup to happen immediately before the synthetic copy, so that clipboard-mutating apps cause minimal data loss.
18. As a privacy-conscious user, I want capture to be entirely local, so that no text leaves the machine just because it was captured.
19. As a developer, I want the capture mechanism behind a platform-agnostic `SelectionBackend` trait, so that future platforms can plug in different implementations.

## Implementation Decisions

- All platform access sits behind a `SelectionBackend` trait so future platforms (Linux/Windows) can plug in different implementations.
- Accessibility capture (primary path): read the frontmost application's focused element and its `AXSelectedText` attribute at shortcut-trigger time, before the popover takes focus; remember the source application (bundle id / pid) for replace-back and focus restoration.
- Automatic clipboard fallback, with no extra user action: back up the current clipboard content (text plus find flags; best-effort for non-text formats) → synthetic ⌘C to the source app → short settle delay → read the clipboard → continue.
- Lifecycle of the fallback backup (single source of truth, shared with spec-04): **Replace** restores it after the paste settles — the user gets their original clipboard back, never the intermediate captured selection; **Copy** discards it — the result intentionally stays on the clipboard; cancel — Escape, focus loss, or closing without an action — restores it immediately.
- If both paths fail, the popover opens with an empty text field and a hint; manual paste/type keeps the app usable.
- Global shortcut registered via the official global-shortcut plugin with a Rust-side handler; default ⌥⌘K; persisted via the settings store so it is ready for the settings window (spec-05); conflicts must surface an error, not fail silently.
- Accessibility onboarding: first-run panel explaining why the permission is needed, with a live status indicator (granted / not granted) re-checked live (poll/refresh) so it updates as soon as the user grants permission — no restart in the happy path; a restart hint is shown if macOS requires it. Deep link to System Settings → Privacy & Security → Accessibility. If permission is missing at trigger time, the popover shows a compact prompt with the same deep link.
- Command surface addition: `capture_selection()` — the UI asks for a capture and never knows which backend ran it.

## Testing Decisions

- Good tests assert external behavior only: given a fake `SelectionBackend`, the `capture_selection` command returns the captured text, or an empty result with a reason — never exposing which path ran.
- Unit (Rust, at the command surface with fakes): AX capture success; fallback path with backup/restore; both-paths-fail returning an empty result.
- Clipboard backup/restore gets a dedicated state machine unit test: backup immediately before the synthetic copy; restore after Replace completes; discard on Copy (the result must remain on the clipboard); restore on cancel, including cancel via focus loss.
- Manual verification per acceptance: the shortcut captures the selection in TextEdit/Safari; in Terminal the clipboard fallback captures automatically and the clipboard is restored afterwards; the permission panel reflects granting without restart.
- Prior art: the seam pattern established in spec-01 (command surface + trait fakes).

## Out of Scope

- Text editing, spell checking, action buttons (spec-03).
- Writing anything back to the source app (spec-04) — this phase only remembers the source app.
- AI provider layer (spec-05).
- The settings-window UI for changing the shortcut (spec-05); the persisted setting and conflict handling land here.
- Direct AX writing of the target field (rejected: unreliable across app categories).
- Any processing of the captured text.

## Further Notes

- This is phase P1 of the vertical slice: platform risk first.
- Acceptance (from PRD): shortcut in TextEdit/Safari captures the selection into the popover; in Terminal (no AX selection) the clipboard fallback captures automatically and the clipboard is restored afterwards; the permission panel reflects granting without restart.
- Risks and mitigations (from PRD): AX selection coverage varies by app (automatic clipboard fallback; manual paste path keeps the app usable); clipboard race with apps that mutate the clipboard (backup immediately before ⌘C; restore after paste settles; best-effort restore documented).
- Source of truth: PRD.md in the repo root.
