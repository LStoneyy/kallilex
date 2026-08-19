# Spec 09 — Popover interaction polish: vibrancy, motion, and feedback at zero idle cost

Status: ready-for-agent
Phase: post-MVP polish (follow-up to spec-07; not part of the PRD vertical slice)
Depends on: spec-07 (confirmed 400×300 dimensions and identity artwork); independent of spec-08

## Problem Statement

From the user's perspective: the popover works, but it feels like a web page,
not like a piece of macOS. The background is a flat opaque rectangle where
every native menu-bar popover shows translucent vibrancy. Buttons snap between
states with no transition, keyboard focus is invisible, and conditional rows
(custom prompt, AI progress, hints) pop in abruptly. Actions give no feedback:
Copy succeeds silently, and during an AI run only a static "Working…" label
sits there. None of this is broken — it is unpolished, and every fix below is
either pure CSS or handled by the system compositor, so the constraint is
explicit: no measurable idle CPU, no added RAM, no new dependencies.

## Solution

The popover gains native macOS vibrancy via Tauri `windowEffects` (the system
composites the blur; the WebView pays nothing), and the frontend gains a thin
layer of CSS-only interaction polish: micro-transitions and pressed states on
buttons, visible `:focus-visible` rings, a one-shot mount animation for
conditional rows, an animated ellipsis while an AI action runs, a transient
"Copied ✓" confirmation, a character count in the toolbar, themed caret and
selection colors, and scroll shadows on the editor driven by the already
existing scroll handler. All motion respects `prefers-reduced-motion`, and no
animation runs while the popover is idle.

## User Stories

1. As a user, I want the popover background to show the translucent blur native macOS popovers have, so that Kallilex feels like part of the OS, not a floating web page.
2. As a user, I want buttons to respond to hover and press with subtle transitions, so that the UI feels alive and reactive.
3. As a keyboard user, I want a clearly visible focus ring when tabbing through controls, so that I always know where I am.
4. As a user, I want the custom-prompt row, hints, and progress row to ease in instead of popping, so that state changes read as intentional.
5. As a user, I want the Copy button to briefly confirm "Copied ✓", so that I know the action worked without checking my clipboard.
6. As a user, I want a subtle animated indicator while an AI action runs, so that I can tell the app is working and not stuck.
7. As a user, I want to see the character count of the captured text, so that I have a sense of length before running Shorten.
8. As a user who scrolls long text, I want a soft shadow at the editor's clipped edges, so that I can tell there is more content above/below.
9. As a user with reduced-motion enabled, I want all decorative motion disabled, so that the app respects my system preference.
10. As a user, I want the popover to consume no CPU while idle, so that a menu-bar utility stays invisible in Activity Monitor.

## Implementation Decisions

- **Vibrancy (the only non-CSS change).** The popover window entry in
  `src-tauri/tauri.conf.json` gains
  `"windowEffects": { "effects": ["popover"], "radius": 10 }` (radius matches
  the existing 10 px CSS `border-radius`). In `src/popover/App.svelte`,
  `.popover`'s `background-color` changes from solid `var(--color-basalt)` to
  `color-mix(in srgb, var(--color-basalt) 80%, transparent)` so the system
  blur shows through; `html`/`body` stay transparent. Text/contrast tokens are
  unchanged — basalt at 80 % over the blur material stays dark enough for
  marble text and the electrum wavy marks. The settings window gets no effect
  (out of scope). If the effect renders wrong on the oldest supported macOS,
  the fallback is reverting only the `color-mix` line to solid basalt — the
  config key is harmless where unsupported.
- **Micro-transitions.** All buttons (`.action-button`, `.result-button`,
  `.custom-run`, `.check-spelling`, `.ai-cancel`, `.ai-hint button`,
  `.permission-banner button`, `.suggestion-popup li button`) get
  `transition: background-color 120ms ease, border-color 120ms ease, color 120ms ease;`
  and a pressed state `:active:not(:disabled) { transform: scale(0.98); }`
  (plus `transform 80ms ease` in the transition list). Transitions run only
  on interaction — zero idle cost.
- **Focus visibility.** A shared rule adds
  `outline: 2px solid var(--color-verdigris); outline-offset: 1px;` under
  `:focus-visible` for all buttons and `.custom-prompt` (replacing its
  `outline: none`). `.capture-field` keeps `outline: none` — it is the primary
  editing surface and a ring around the whole editor would be noise.
- **Mount animation.** One keyframe (`@keyframes row-in`: opacity 0→1,
  `translateY(-3px)`→0, 140 ms ease-out, run once on mount) applied to
  `.permission-banner`, `.custom-row`, `.ai-hint`, `.ai-progress`, and
  `.suggestion-popup`. These elements are conditionally rendered (`{#if}`), so
  the animation fires only on state change, never continuously.
- **Working indicator.** `.ai-progress-label` renders "Working" and gains an
  animated ellipsis via `::after` with `content` cycled by a
  `steps()`-timed keyframe (e.g. 1.2 s, `""`→`"."`→`".."`→`"…"`). The element
  exists only while `aiRunning` is true, so the animation cannot run while
  idle. The label's accessible text stays stable ("Working…" via
  `aria-label`) so tests and screen readers don't see flapping content.
- **Copy feedback.** After a successful copy, the Copy button shows
  "Copied ✓" for 1500 ms, then reverts to "Copy". Implementation: one boolean
  state + `setTimeout`; the timeout is cleared on re-copy and on component
  destroy. The button stays enabled (re-copy restarts the timer). Failure
  paths are unchanged (existing error display).
- **Character count.** The toolbar (currently `justify-content: flex-end`)
  becomes `justify-content: space-between` with a new left-aligned
  `.char-count` span — `{text.length} chars`, ash color, 11 px, rendered only
  when `text` is non-empty. Derived directly from existing state; no new
  listeners.
- **Themed caret & selection.** `.capture-field` and `.custom-prompt` get
  `caret-color: var(--color-verdigris)`; `.capture-field::selection` gets
  `background-color: color-mix(in srgb, var(--color-verdigris) 35%, transparent)`.
- **Editor scroll shadows.** Two pseudo-elements on `.editor` (`::before`
  top, `::after` bottom): 12 px basalt→transparent gradients,
  `pointer-events: none`, positioned above the textarea but below
  `.suggestion-popup` (z-index between 1 and 20), toggled via classes
  `.can-scroll-up` / `.can-scroll-down` with an opacity transition. The
  classes are set inside the **existing** `handleScroll` handler (which
  already syncs the backdrop) plus on input/capture — no new scroll listener,
  a few comparisons per scroll event. The backdrop/textarea alignment used for
  spell-check marks is not touched; marks must remain clickable.
- **Reduced motion.** All `transform`s in transitions, the `row-in`
  animation, and the ellipsis animation are wrapped in
  `@media (prefers-reduced-motion: no-preference)`. Color transitions may
  stay. With reduced motion, the progress label reads a static "Working…".
- **Resource guard (acceptance-relevant).** No `setInterval`, no
  `requestAnimationFrame`, no continuously running animation while the
  popover is idle (the only persistent keyframe animation is the ellipsis,
  gated on `aiRunning`). No new npm or cargo dependencies. Window dimensions,
  positioning, and all Rust code paths are untouched (config-only change on
  the Tauri side).

## Testing Decisions

- Existing Rust and frontend suites stay green; no test is deleted or
  weakened.
- New component tests (vitest + testing-library, fake timers where needed):
  - Copy shows "Copied ✓" after a successful copy and reverts to "Copy"
    after the timeout; a second copy restarts cleanly.
  - The character count renders for non-empty text, updates on input, and is
    absent when the editor is empty.
  - The AI progress row still exposes stable accessible text while running
    (guards the ellipsis implementation against flapping test-visible text).
- Regression guard: existing spell-check mark tests must still pass —
  the scroll-shadow pseudo-elements must not intercept mark clicks.
- Observational checks (manual, noted in the commit/PR description):
  vibrancy blur visible over a bright and a dark desktop; focus ring visible
  when tabbing; reduced-motion (System Settings → Accessibility) disables
  slide/scale/ellipsis motion; Activity Monitor shows ~0 % CPU for the
  WebView with the popover open and idle.

## Out of Scope

- Any layout or dimension change — 400×300 stays (confirmed in spec-07).
- Settings window styling or vibrancy.
- Light-theme work (dark mode first, per README).
- Animated or state-dependent tray icons — roadmap.
- Sounds/haptics, spring/physics animation libraries, or any new dependency.
- Changes to capture, spell-check, replace-back, or provider behavior.

## Further Notes

- The vibrancy `radius` and the CSS `border-radius` must stay in sync (both
  10 px); if one changes later, change both.
- `windowEffects` is macOS-only in effect; the key is inert elsewhere and the
  app is macOS-only anyway.
- Ellipsis-in-`::after` keeps animated content out of the DOM text, which is
  what keeps both tests and VoiceOver stable.
- Source of truth: PRD.md in the repo root; visual identity tokens in
  README.md ("Attic Oxide"); layout facts (flex column, scrolling editor,
  fixed rows) audited in spec-07.
