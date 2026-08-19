# Spec 04 — Replace-back: writing results into the source app

Status: ready-for-agent
Phase: P3 of the Kallilex macOS MVP (source: PRD.md, approved 2026-08-19)
Depends on: spec-02 (capture & source-app memory), spec-03 (popover editor)

## Problem Statement

From the user's perspective: the most annoying part of using any text tool is the trip back — copying the result, switching windows, finding the cursor, pasting, and discovering the clipboard got clobbered along the way. If Kallilex can't put the corrected text back where it came from, reliably and safely, the fast path (select → shortcut → action → replace) is broken at exactly its last step.

## Solution

An explicit Replace button writes the result straight back into the source application: the clipboard is backed up, the result is placed on the clipboard, focus returns to the remembered source app, a synthetic ⌘V pastes, and the original clipboard content is restored. A Copy button puts the result on the clipboard (overwriting it, no restore) and closes the popover. Nothing is ever written into another app automatically — only an explicit button click triggers write-back, and Escape/cancel leaves everything untouched.

## User Stories

1. As a writer, I want a Replace button that writes the result back into the app the text came from, so that the corrected text is in place with one click.
2. As a writer, I want my previous clipboard content restored after Replace, so that Kallilex doesn't destroy what I had copied.
3. As a writer whose text was captured via the clipboard fallback, I want Replace to restore what was on my clipboard *before* the capture, so that the intermediate captured selection never masquerades as my original clipboard content.
4. As a writer, I want a Copy button that copies the result to the clipboard, so that I can paste it myself wherever and whenever I want.
5. As a user, I want Copy to close the popover, so that the workflow ends cleanly.
6. As a user, I want Escape or cancel to leave the source app and my clipboard completely untouched, so that aborting is always safe.
7. As a writer, I want focus to return to the source app before the paste happens, so that the text lands in the right place.
8. As a writer, I want the end-to-end no-AI path to work (select → shortcut → fix a typo → Replace), so that the tool is useful even without any provider configured.
9. As a writer in a rich-text app, I want documented plain-text behavior, so that I know replacement arrives as plain text (documented behavior, not a bug).
10. As a writer, I want the clipboard backup to happen immediately before the result is written, so that clipboard races cause minimal data loss.
11. As a user, I want the popover to close after Replace completes, so that I continue working where I left off.
12. As a user, I want Replace to be the only thing that ever writes into another app, so that Kallilex never surprises me — write-back is never automatic.
13. As a privacy-conscious user, I want Replace to work without any network involvement, so that local spellcheck fixes never leave the machine.
14. As a developer, I want the write-back mechanism behind the command surface, so that it is testable with fakes (no real key events in unit tests).
15. As a user with a slow source app, I want the paste to settle before the clipboard is restored, so that the restore doesn't clobber the paste.

## Implementation Decisions

- Mechanism: clipboard + synthetic ⌘V only. No direct AX writing of the target field (rejected as unreliable across app categories).
- Replace is triggered exclusively by an explicit button click — never automatically.
- Replace sequence: save clipboard → write result to clipboard → focus the remembered source app (by pid) → synthetic ⌘V → wait for the paste to settle → restore the saved clipboard.
- Coordination with the capture fallback (spec-02): if a fallback backup already exists, that backup is the restore target and the clipboard is **not** re-saved — at that point it holds the intermediate captured selection, not the user's original content. There is never more than one pending backup.
- Copy copies the result to the clipboard (overwriting it; no restore) and closes the popover; any pending fallback backup is discarded so the result stays on the clipboard.
- Cancel — Escape or the popover losing focus — leaves everything untouched; any pending clipboard backup from the capture fallback (spec-02) is restored immediately.
- Formatting is not preserved: Kallilex works on plain text; replacement in rich-text contexts arrives as plain text — documented behavior.
- Command surface: `replace_back(text)` — the UI passes the final text; the command orchestrates backup, write, focus, paste, restore.
- Clipboard backup/restore and synthetic key events live in the clipboard module of the core, reusable by both the capture fallback (spec-02) and replace-back.

## Testing Decisions

- Good tests assert external behavior only: `replace_back(text)` against fakes must produce the observable orchestration order (backup → write → focus → paste → restore) without asserting internal state.
- Unit (Rust): clipboard backup/restore state machine — restore after completion, restore on cancel (Escape and focus loss), restore after the settle delay, discard on Copy, and the fallback-coordination case (an existing capture backup is the restore target; no re-save of the intermediate clipboard); replace-back orchestration order with fake clipboard/keyboard/backend collaborators.
- The end-to-end no-AI acceptance path is manual: select in Notes/Mail → shortcut → fix a typo via spellcheck → Replace → the corrected text stands in the source app and the previous clipboard content is back.
- Manual matrix (subset, full matrix in spec-06): capture + replace in TextEdit, Notes, Mail, Safari, Chrome, VS Code, Terminal, Slack, and one password-secure field (expected fallback/failure behavior); clipboard restoration verified in each.
- Prior art: the command-surface-with-fakes pattern from specs 01–03.

## Out of Scope

- AI action wiring (spec-05) — this phase is verified end-to-end with spellcheck only.
- Inline diff view or word-level diff (roadmap; the result simply replaces the editable text).
- Optional per-profile clipboard restore (open item; watch for user feedback).
- Preserving rich formatting.

## Further Notes

- This is phase P3 of the vertical slice.
- Acceptance (from PRD): end-to-end without AI — select in Notes/Mail → shortcut → fix a typo via spellcheck → Replace → the corrected text stands in the source app and the previous clipboard content is back.
- Risks and mitigations (from PRD): clipboard race (backup immediately before writing; restore after paste settles; best-effort restore documented); focus restoration flakiness (focus the source app by remembered pid before ⌘V; small delay; verify AX focus if needed).
- Source of truth: PRD.md in the repo root.
