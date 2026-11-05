# Spec ios-22 — App setup for the keyboard

Status: ready-for-agent
Phase: Keyboard K5 (setup)
Depends on: ios-19

## Problem Statement

A keyboard is useless until the user adds it in Settings. For the AI
features they also have to allow Full Access, behind a system warning that
sounds alarming. Neither step can happen inside Kallilex, and the keyboard
can't open the app. The app has to guide the user through both steps,
explain Full Access honestly before Apple's warning appears, and offer the
layout choice.

## Solution

- An **onboarding step "Kallilex Keyboard"** after the share-sheet guide.
- A **Settings → Keyboard** section with:
  - the same guide;
  - the layout choice;
  - a test field.
  (No status row: there's no public way to detect the added keyboard. Only a
  private KVC key exists, which must not ship. Spike unknown 12.)

## User Stories

1. As a new user, I want onboarding to show me how to add the Kallilex
   keyboard, so that I find it at all.
2. As a user, I want to understand what Full Access means for Kallilex
   before I see Apple's warning, so that I can decide calmly.
3. As a user, I want one tap that takes me as close to the keyboard
   settings as iOS allows.
4. As a user, I want to choose QWERTZ or QWERTY.
5. As a user, I want a test field in the app to try the keyboard.
6. As a user who skipped the step, I want to find it again in Settings.

## Implementation Decisions

### Onboarding

- `OnboardingFlow` (KallilexKit/Presentation) gets a new step
  `.keyboardGuide` after `.shareSheetGuide` and before `.done`. It can be
  skipped ("Later"). The flow tests cover the new order.
- **`KeyboardGuideView`** (KallilexUI, next to `ShareSheetGuideView`) shows:
  1. a three-step illustration: Settings → General → Keyboard → Keyboards
     → Add New Keyboard → Kallilex;
  2. "Allow Full Access" with the explanation:
     - **Why:** "Full Access lets the keyboard send the Scratchpad text to
       your AI provider and copy results.";
     - **Never:** "Kallilex never records or sends what you type. Only the
       Scratchpad text goes to your provider, when you tap a prompt.";
     - **Without it:** "Typing, Insert and dictation work without Full
       Access."
  3. a button **Open Settings**, which opens
     `UIApplication.openSettingsURLString` (the app's page, which lists
     "Keyboards" for apps with a keyboard);
  4. a short note: "iOS will warn that the keyboard can transmit what you
     type. This is the standard warning for every keyboard with Full
     Access."
- Strings EN/DE. German uses the informal "du", like the existing app
  strings.

### Settings → Keyboard

A new section in `SettingsView` (`settings.keyboard`):

- **How to add the keyboard:** pushes `KeyboardGuideView`.
- **Layout:**
  - a picker, Automatic / QWERTZ (German) / QWERTY (English);
  - writes `AppSettings.keyboardLayout` (ios-17) through `SettingsService`;
  - the keyboard reads it on its next `viewWillAppear`.
- **Try the keyboard:**
  - a multi-line text field (`settings.keyboard.testField`) with a hint
    "Switch to Kallilex with 🌐";
  - focused, it lets the user test the keyboard without leaving the app.
- **Dictation** stays in its own section (ios-20).

### Keyboard side

- The keyboard applies `keyboardLayout` (nil → device language).
- No other change.

## Testing Decisions

- **`OnboardingFlow` unit tests:**
  - the new step order;
  - skip goes to `.done`;
  - back navigation.
- **UI tests:**
  - onboarding shows the keyboard step after the share-sheet guide;
    "Later" finishes onboarding;
  - Settings → Keyboard: the guide opens;
  - the layout picker persists across a relaunch (`resetState: false`);
  - the keyboard harness shows QWERTY after choosing it
    (`keyboard.key.y` is in the bottom letter row);
  - the accessibility audit on `KeyboardGuideView` and the section.
- **Manual (device):**
  - Open Settings lands on the app's page with "Keyboards".

## Out of Scope

- An in-app keyboard tutorial beyond the guide and the test field.
- Detecting Full Access from the app (there's no public API; the keyboard
  itself shows the Full Access card).

## Further Notes

- PLAN-keyboard.md §4.1.
- The onboarding stays skippable throughout. App Review 5.1.2(i) consent
  for cloud providers is still asked per profile (ios-07) and inside the
  keyboard (ios-19).
