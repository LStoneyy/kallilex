# Spec 07 — Icon & popover polish: identity artwork and final dimensions

Status: ready-for-agent
Phase: post-MVP polish (follow-up to the v0.1.0 release; not part of the PRD vertical slice)
Depends on: spec-06 (release pipeline in place; artwork ships with the next release)

## Problem Statement

From the user's perspective: Kallilex still wears someone else's face. The menu
bar shows the stock Tauri icon — a full-color app icon where macOS expects a
monochrome template glyph, so it clashes with every other menu-bar item and
ignores the menu bar's light/dark appearance. The Dock-less app's only visual
identity — the icon seen in Finder, the Gatekeeper dialog, and System Settings
— is a placeholder. And the popover's dimensions (400×300) were an assumption
from spec-01 that was never confirmed against the real content; the PRD lists
"exact popover dimensions and tray-icon artwork" as an open item to resolve.

## Solution

Kallilex gets its own artwork in the Attic Oxide identity: a custom app icon
(basalt/verdigris, from an SVG source checked into the repo) generated into the
full icns/png set, and a dedicated monochrome tray glyph delivered as a macOS
template image so it adapts to the menu bar automatically. The unused Windows
Store placeholder logos are removed. The popover's fixed size is confirmed (or
minimally adjusted) against a content-fit audit, closing the PRD's open item.

## User Stories

1. As a user, I want a monochrome menu-bar icon that matches macOS conventions, so that Kallilex looks native next to Wi-Fi, battery, and clock.
2. As a user, I want the tray icon to adapt to light and dark menu bars automatically, so that it is always legible.
3. As a user, I want the tray icon to render crisply on Retina displays, so that it never looks blurry.
4. As a user, I want a distinctive app icon in Finder, the Gatekeeper dialog, and System Settings (Accessibility, Privacy & Security), so that I can recognize the app I'm approving.
5. As a user, I want the popover to show all its content — editor, spell-check marks, action row, result row, privacy badge — without clipping or scrollbars at typical text lengths, so that the UI never feels broken.
6. As a contributor, I want the icon source (SVG) checked into the repo with a documented regeneration path, so that artwork changes are reproducible, not binary-only drops.

## Implementation Decisions

- Icon sources live in a new `assets/` directory as SVG: `assets/icon.svg`
  (app icon master) and `assets/tray-template.svg` (tray glyph). SVGs are the
  source of truth; generated rasters are committed alongside them.
- App icon motif: a stylized "K" ligature/monogram on a basalt (`#17161A`)
  rounded-square background with a verdigris (`#2FAF9B`) glyph and a restrained
  Attic Clay (`#E46846`) accent — Attic Oxide tokens from the README, no
  gradients beyond a subtle surface treatment, readable at 32 px.
- App icon pipeline: render `assets/icon.svg` to a 1024×1024 PNG, then run
  `pnpm tauri icon <png>` to regenerate `src-tauri/icons/` (32x32, 128x128,
  128x128@2x, icon.icns, icon.ico, icon.png). Delete the unused
  `Square*Logo.png` and `StoreLogo.png` Windows Store placeholders and keep
  `tauri.conf.json`'s `bundle.icon` list unchanged (it never referenced them).
- Tray glyph: the same "K" motif reduced to a single solid shape — pure black
  with alpha only (template-image requirement; macOS recolors it). Shipped as
  `src-tauri/icons/tray.png` (22×22 pt logical: 22 px @1x) and
  `src-tauri/icons/tray@2x.png` (44 px), rendered from
  `assets/tray-template.svg`.
- Tray wiring in `src-tauri/src/lib.rs`: the `TrayIconBuilder` stops using
  `app.default_window_icon()` and instead loads the dedicated tray image with
  `.icon_as_template(true)`, so macOS handles light/dark and the highlighted
  (menu-open) state.
- Rendering SVG → PNG happens at development time, not at build time: use
  `rsvg-convert` or ImageMagick locally, commit the generated PNGs, and
  document the exact commands in a short `assets/README.md`. CI and
  `tauri build` never need an SVG renderer.
- Popover dimensions: run a content-fit audit with realistic content (a
  ~1000-character captured text, spell-check marks active, action row, result
  row with privacy badge, an inline provider error visible). 400×300 stays the
  confirmed v1 size if nothing clips; if content clips, increase the fixed
  height in 20 px steps to at most 400×360 (width stays 400). The popover
  remains non-resizable; `width`/`height`/`minWidth`/`minHeight` in
  `tauri.conf.json` stay consistent with each other.
- The final confirmed dimensions are recorded in this spec's Further Notes
  (edit on completion) so the PRD's open item is closed with a written answer.

## Testing Decisions

- Good verification here is observational — artwork and layout have no unit
  seams: existing Rust/frontend suites must stay green and `pnpm tauri build`
  must produce a bundle whose `Kallilex.app/Contents/Resources/icon.icns` is
  the new artwork.
- Manual matrix (screenshots attached to the PR/commit description): tray icon
  in light and dark menu bar, on a Retina display, and while the tray menu is
  open (template highlight state); app icon in Finder, in the Gatekeeper
  "Open Anyway" flow, and in System Settings → Accessibility.
- Popover audit: the content-fit scenario above shows no clipped controls and
  no scrollbars around the action/result rows (the editor itself may scroll);
  spell-check marks remain clickable after any height change (regression guard
  for the earlier invisible-marks fix).
- No new automated tests; no existing test may be deleted or weakened.

## Out of Scope

- Any change to popover behavior, positioning logic, or window management
  beyond the fixed dimensions.
- Light-theme UI work (dark mode first, per README).
- Animated or state-dependent tray icons (e.g. busy indicator) — roadmap.
- Onboarding/first-run visual changes.
- A marketing/website icon set beyond what the app bundle needs.

## Further Notes

- Open item being closed (from PRD §Open items via spec-06): "exact popover
  dimensions and tray-icon artwork". Final dimensions: **400×300 confirmed**
  (unchanged). Content-fit audit result: the popover root is a flex column in
  which only the editor flexes (`flex: 1; min-height: 0`) and scrolls; the
  toolbar, action row, custom row, result row with privacy badge, and the
  3-line-clamped inline error are fixed-height rows that total ≤ ~136 px in
  the audit scenario, leaving ~144 px (~7 lines) of visible editor at 300 px
  height — no control is clipped and no scrollbar appears outside the editor.
  Tray-icon artwork: verdigris "K" + Attic Clay correction squiggle
  (assets/icon.svg), shipped as a pure black+alpha template image
  (assets/tray-template.svg → icons/tray.png, tray@2x.png).
- macOS template-image rules: pure black + alpha, no color; sizing follows the
  22 pt menu-bar convention. Color in the tray is a defect, not a style choice.
- The icon SVGs are original work created for this project (no third-party
  artwork, fonts converted to paths to avoid font dependencies).
- Acceptance: a clean build shows the new app icon in Finder/Gatekeeper and a
  correct template tray icon in both menu-bar appearances; the popover shows
  the audit scenario without clipping; the Windows Store placeholder PNGs are
  gone; all existing checks stay green.
- Source of truth: PRD.md in the repo root; visual identity tokens in
  README.md ("Attic Oxide").
