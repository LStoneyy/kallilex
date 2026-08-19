# Spec 03 — Popover & spell check

Status: ready-for-agent
Phase: P2 of the Kallilex macOS MVP (source: PRD.md, approved 2026-08-19)
Depends on: spec-01 (scaffold), spec-02 (capture)

## Problem Statement

From the user's perspective: even with text captured, the popover is just an empty frame. The user needs to see their text, fix spelling mistakes in place, and reach the actions that will transform the text. Spelling is the most frequent everyday need, and it must work offline and instantly, or the tool isn't worth keeping in the menu bar.

## Solution

The popover becomes a working editor: the captured text sits in an editable area; misspelled words are marked inline automatically and on demand; clicking a marked word shows the native macOS suggestion list and applies a suggestion with one click. Below the text, an action row presents Rewrite, Shorten, Improve clarity, and Custom (a one-line prompt input). All four actions exist as UI in this phase (not yet wired to a provider), together with the result row's Replace and Copy buttons.

## User Stories

1. As a writer, I want the captured text displayed in an editable field, so that I can read and change it immediately.
2. As a writer, I want misspelled words marked automatically when the popover opens, so that I see problems at a glance without running anything.
3. As a writer, I want to click a marked word and see the native macOS suggestion list, so that corrections are one click away.
4. As a writer, I want choosing a suggestion to replace the word in my text, so that I never retype a correction.
5. As a writer, I want spell check to run on demand while I edit my own text, so that my changes are checked too.
6. As a writer, I want spell checking to use my system-preferred languages, so that it matches how I actually write.
7. As a writer, I want spell checking to work fully offline, so that it never depends on a network or a configured provider.
8. As a writer, I want the action row with Rewrite, Shorten, Improve clarity, and Custom, so that the common transformations are one click away.
9. As a writer, I want Custom to open a one-line prompt input, so that quick instructions stay quick.
10. As a user, I want Replace and Copy buttons visible in the result row, so that the end of the workflow is always in sight.
11. As a user, I want Escape to close the popover with no side effects, so that canceling is always safe.
12. As a user, I want the popover to keep keyboard focus while I edit, so that typing feels natural.
13. As a user, I want a compact single-column layout, so that the popover stays small and unobtrusive.
14. As a user, I want spell-check marks visually distinct (Electrum squiggle/underline), so that they are readable at a glance in the dark theme.
15. As a user, I want an AI result to replace the editable field's content while remaining editable, so that I can review and tweak before applying (the wiring arrives in spec-05; the affordance exists here).
16. As a privacy-conscious user, I want spell checking to carry no privacy badge, so that it is unmistakably local.
17. As a developer, I want spell checking behind a `SpellChecker` trait with a request/response model, so that it is testable with fakes and portable to other platforms.
18. As a developer, I want spell-check marks and click-to-correct as UI components driven purely by command results, so that the logic stays testable at the command surface.

## Implementation Decisions

- Spell checking is local, offline, and independent from AI: macOS-native NSSpellChecker via an objc2 bridge, with all AppKit calls marshalled to the main thread; spell checking is treated as a pure request/response operation.
- Uses the user's system-preferred spell-check languages; no language picker in v1.
- Behavior: misspelled words are marked inline (squiggle/underline in Electrum); clicking a marked word shows the native suggestion list; choosing a suggestion replaces the word in the text field.
- Spell check runs automatically when the popover opens with captured text, and on demand while editing.
- Popover sections (single column, compact): editable text area with captured text/result; inline spell-check marks; action row (Rewrite, Shorten, Improve clarity, Custom with one-line prompt input); result row (Replace, Copy, and the privacy badge — the badge is populated in spec-05).
- Command surface: `spellcheck(text)` returns marked ranges and suggestions; the UI applies corrections.
- All four AI actions exist as UI in this phase, not yet wired to a provider (spec-05 wires them).
- Learn/ignore-to-dictionary and grammar checking are explicitly deferred (roadmap).
- Visual identity: Attic Oxide tokens from spec-01; one strong accent per state.

## Testing Decisions

- Good tests assert external behavior only: `spellcheck(text)` against a fake `SpellChecker` returns ranges and suggestions for fixture strings; the UI component tests drive the popover state machine, not AppKit internals.
- Unit (Rust): the spellcheck command with a fake checker over fixture strings (clean text, misspellings, suggestions).
- UI (Svelte component tests): popover state machine — idle → checking → result → replaced; mark display; click-to-correct applies the chosen suggestion to the text; the custom prompt input opens and closes.
- Manual: marks visible and clickable in the real popover; native suggestions appear; applying one edits the text.
- Prior art: the command-surface-with-fakes pattern from specs 01–02; Svelte component tests are the secondary seam established in spec-01.

## Out of Scope

- Wiring the actions to a provider (spec-05) — buttons exist but send no requests.
- Replace/Copy write-back behavior (spec-04).
- Privacy badge content (spec-05).
- The spellcheck on/off toggle in settings (arrives with the settings window, spec-05).
- Learn/ignore words, grammar checking, Harper integration (roadmap).
- Language picker.

## Further Notes

- This is phase P2 of the vertical slice.
- Acceptance (from PRD): misspelled words are marked; clicking offers native suggestions; applying one edits the text; all four actions exist as UI (not yet wired to a provider).
- Key technical risk (from PRD): NSSpellChecker main-thread constraints — all AppKit calls marshalled to the main thread; spellcheck treated as request/response.
- Source of truth: PRD.md in the repo root.
