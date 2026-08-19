# Kallilex — Project Instructions

Kallilex is a macOS menu-bar writing utility: Tauri 2 + Rust (`src-tauri/`) with
Svelte + TypeScript (`src/`). Source of truth for product behavior is `PRD.md`;
implementation work is sliced into specs under `issues/` (spec-01 … spec-06).

## Issue Workflow

Issues in `issues/` are implemented strictly one at a time, in order, by the
main agent acting as orchestrator (subagents do the bounded work). Each issue
runs through this fixed loop:

1. **Implementation** — Orchestrator reads the spec, decides the design, and
   delegates bounded implementation to the `coder` subagent with a
   self-contained prompt (goal, scope, non-goals, acceptance criteria).
2. **Review** — Orchestrator inspects the actual diff (`git status`,
   `git diff`), then delegates a review of the final diff to the `reviewer`
   subagent. Findings are validated by the orchestrator, not applied blindly.
3. **Fix / Test** — Blocking and required findings go back to `coder` as
   bounded fix tasks; material fixes are re-reviewed. Checks (build, tests,
   lint) are run via the `tester` subagent or directly; the orchestrator
   independently verifies important results. Never proceed with known related
   failures.
4. **Commit** — The orchestrator commits the completed issue itself (subagents
   never commit). One issue = one coherent commit (or a small series if it
   genuinely helps history). Only intended files are staged.
5. **Stop & report** — After the commit, stop. Give the user a short review:
   what was implemented, what the review found and how it was resolved, what
   was tested, known risks/open points. Do not start the next issue without
   the user's go-ahead.

## Ground Rules

- Only one writing subagent at a time; parallelize only read-only work.
- Tests assert external behavior at the command surface / component boundary,
  against fakes for the `Provider`, `SpellChecker`, `SelectionBackend`, and
  `SettingsStore` traits — never internal state.
- Secrets never go into subagent prompts, the Tauri Store, or config files.
- Out-of-scope items listed in a spec stay out of scope, even when convenient.
