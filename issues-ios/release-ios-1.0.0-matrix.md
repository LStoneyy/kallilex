# iOS Release 1.0.0 — Host App Matrix

Release: 1.0.0
Date: 
Tester: 
Device: 
Kallilex build: 

## Instructions

For each app in the list:

1. **Appear:** Does Kallilex appear in the share sheet?
2. **Text intact:** Is the selected text passed to Kallilex without corruption or loss?
3. **Paste-back:** After Copy, is the selection still there? Does selecting the original text again and pasting replace it? (Spike ios-01 found the selection is lost in Notes on iOS 27; record per app.)

Mark each cell with:
- ✓ Pass
- ✗ Fail (describe the issue)
- — N/A (the app doesn't support share, or text selection is not available)

## Matrix

| App | Appear | Text intact | Paste-back | Notes |
|---|---|---|---|---|
| Safari (with text selection) | | | | |
| Safari (page only, no selection) | | | | |
| Mail (compose) | | | | |
| Mail (read) | | | | |
| Notes | | | | |
| Messages | | | | |
| WhatsApp | | | | |
| Pages | | | | |
| Google Docs | | | | |
| Chrome | | | | |

## Keyboard (ios-19)

On the device, with Kallilex Keyboard added and Full Access on. Per app:

1. **Take-over:** select text, switch to Kallilex (🌐). Does the selection land in the Scratchpad?
2. **Replace:** run a prompt, tap "Markierung ersetzen". Is exactly the selection replaced?
3. **Undo right after Insert:** is "Eingefügt · Rückgängig" still shown immediately after Insert? (It hides itself if the host's context changes unexpectedly; web views are the risk.)
4. **Undo:** does it restore the original text exactly (emoji, accents, newlines)?

| App | Take-over | Replace | Undo shown | Undo restores | Notes |
|---|---|---|---|---|---|
| Notes | | | | | |
| Mail (compose) | | | | | |
| Messages | | | | | |
| Safari (address bar) | | | | | |
| Safari (`<textarea>`) | | | | | |
| Safari (`contenteditable`) | | | | | |
| WhatsApp | | | | | |
| Signal | | | | | |
| Slack | | | | | |
| Google Docs | | | | | |
| Pages | | | | | |
| Gmail | | | | | |
| Notes, ~3,000-character selection | | | | | |

## Summary

- Total apps tested: 10
- Passes: 
- Failures: 
- N/A: 

## Issues found

(List any failures with reproduction steps and workarounds, if any.)

## Sign-off

**Tester:** 
**Date:** 
**Status:** Ready for release / Requires fixes
