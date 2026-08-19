# Kallilex artwork sources

SVGs in this directory are the source of truth for all app artwork (Attic
Oxide identity: basalt `#17161A`, verdigris `#2FAF9B`, Attic Clay `#E46846`).
Generated rasters are committed; CI and `tauri build` never render SVGs.

## Files

- `icon.svg` — app icon master (1024×1024): verdigris monoline "K" with an
  Attic Clay correction squiggle on a basalt rounded square.
- `tray-template.svg` — menu-bar glyph (22×22 pt): same motif as a pure
  black + alpha macOS template image (no color — macOS recolors it for
  light/dark menu bars and the highlighted state).
- `icon-1024.png` — rendered app-icon master, input for `tauri icon`.

## Regenerating

Requires `rsvg-convert` (`brew install librsvg`). From the repo root:

```sh
# App icon: SVG → 1024px PNG → full icns/ico/png set in src-tauri/icons/
rsvg-convert -w 1024 -h 1024 assets/icon.svg -o assets/icon-1024.png
pnpm tauri icon assets/icon-1024.png

# tauri icon also emits Windows Store logos we don't ship — remove them
rm -f src-tauri/icons/Square*Logo.png src-tauri/icons/StoreLogo.png

# Tray template image (22 pt logical, @1x and @2x)
rsvg-convert -w 22 -h 22 assets/tray-template.svg -o src-tauri/icons/tray.png
rsvg-convert -w 44 -h 44 assets/tray-template.svg -o src-tauri/icons/tray@2x.png
```

Template-image rule: `tray-template.svg` must stay pure black with alpha
only. Color in the tray glyph is a defect, not a style choice.
