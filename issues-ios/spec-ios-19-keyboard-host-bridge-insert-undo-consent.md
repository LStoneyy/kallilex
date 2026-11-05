# Spec ios-19 — Host bridge: take selection, Insert, Undo, consent, Full Access

Status: ready-for-agent
Phase: Keyboard K3 (AI flow)
Depends on: ios-18

## Problem Statement

What makes the keyboard worth having is getting text out of the host app
and back in without copy and paste:

- take over the selection;
- run a prompt;
- **Insert**, which replaces the selection;
- undo that if it was wrong.

On top, the keyboard has to ask for AI consent where needed (App Review
5.1.2(i)) and explain clearly what works without Full Access (4.4.1).

## Solution

- A **`HostBridge`** (KallilexUI) between `EditorSession` and the host's
  `TextDocument` (ios-17). It covers:
  - the selection snapshot and take-over rules;
  - Insert;
  - the guarded Undo Insert.
- The keyboard UI gets:
  - the **Insert** button;
  - the "Take selection" chip;
  - **compact consent**;
  - the **Full Access card**;
  - the hints for hosts that don't share the selection.

## User Stories

1. As a user, I want my selected text to appear in the Scratchpad when I
   switch to Kallilex, so that I can run a prompt on it right away.
2. As a user who already has text in the Scratchpad, I want a "Take
   selection" chip instead of losing my text.
3. As a user, I want Insert to replace the text I selected, so that I don't
   have to paste by hand.
4. As a user, I want Insert to insert at the cursor when nothing is
   selected, and the button to say which it will do.
5. As a user, I want Undo right after Insert, so that a wrong result is
   easy to take back.
6. As a user of a cloud provider, I want to be asked for consent before my
   text is sent, inside the keyboard.
7. As a user without Full Access, I want to understand why prompts don't
   run and how to fix it, while typing and Insert keep working.
8. As a user in an app that doesn't share the selection, I want a hint that
   tells me what to do instead.

## Implementation Decisions

### HostBridge

```swift
@MainActor
public final class HostBridge {
    public init(host: any TextDocument)
    public private(set) var selectionLength: Int?          // nil = no selection reported
    public func refresh()                                   // on selectionDidChange/textDidChange
    public func takeSelection() -> String?                  // reads selectedText now
    public var insertWillReplaceSelection: Bool { get }
    public func insert(_ text: String)
    public var canUndoInsert: Bool { get }
    public func undoInsert()
    public func invalidateUndo()                            // any other edit or keyboard switch
}
```

- **Take-over rules** (`KeyboardModel`, on `viewWillAppear` and on
  `selectionDidChange`):
  - When a non-empty `selectedText` arrives and the Scratchpad is empty, or
    still holds the last taken-over selection unchanged, put the selection
    into `session.text` automatically.
  - Otherwise show the chip "Take selection" ("Markierung übernehmen";
    identifier `keyboard.takeSelection`).
  - Taking a selection while a result is shown replaces the text.
    `EditorSession`'s own Undo brings the previous text back.
- **Insert:**
  - It calls `host.insertText(session.text)`, which replaces the host's
    selection if there is one.
  - It records `inserted = session.text` and `replaced = selectedText`
    (possibly nil).
  - Label: "Replace selection" ("Markierung ersetzen") when
    `insertWillReplaceSelection`, otherwise "Insert" ("Einfügen").
    Identifier `keyboard.insert`.
  - Disabled while the Scratchpad is empty or a run is in flight.
  - **Typing target App:** Insert stays available and inserts the
    Scratchpad text the same way.
- **Undo Insert** (identifier `keyboard.undoInsert`), shown in the action
  row as "Inserted · Undo" for as long as `canUndoInsert` is true:
  - **Allowed only while:** `documentContextBeforeInput` ends with the last
    `min(200, inserted.count)` characters of `inserted`; no `insertText` or
    `deleteBackward` from us since; and no `selectionDidChange` that moved
    the cursor away. `textDidChange` with an unchanged context is fine.
  - **Action:** `inserted.count` × `deleteBackward()` (counted in
    `Character`s), then `insertText(replaced)` if `replaced` isn't nil.
  - **Spike result (unknown 11):** for hosts where the count doesn't match,
    there's no reliable detection. If the spike finds a whole class of
    hosts (e.g. web views) that miscounts, disable the button whenever the
    inserted text contains the problem characters (newlines, emoji,
    combining marks) and document it.
  - The button disappears after 30 s or on the next edit.
- **Hosts that don't share the selection:** after a `selectionDidChange`
  where `selectedText` is nil but the cursor context changed, show once per
  keyboard session: "This app doesn't share selected text with keyboards.
  Type or dictate in the Scratchpad, or use Share → Kallilex."

### Consent

- `EditorSession` already returns `.consentRequired(profile)`.
- In the keyboard, the chips row shows a compact `ConsentView`:
  - the profile name and host;
  - the sentence "The text in the Scratchpad is sent to <host> to be
    processed." (new string; the app's sentence says "the text you share");
  - **Allow** and **Not now**.
- Allow goes through `session.grantConsentAndRetry()`, which writes the
  consent through `SettingsServiceConsentGranter`. Not now calls
  `declineConsent()`.
- If the consent sentence doesn't fit in the 44 pt row, the consent view
  temporarily takes the Scratchpad's space as well, with the Scratchpad
  text hidden behind it.

### Full Access states

- **On-device provider** (spike unknown 1): runs without Full Access.
- **Network provider without Full Access:** the chips are shown but tapping
  one shows the **Full Access card** in the chips area (identifier
  `keyboard.fullAccessCard`):
  - "Prompts need Full Access to reach your AI provider. Typing, Insert and
    dictation work without it.";
  - "Settings → General → Keyboard → Keyboards → Kallilex → Allow Full
    Access";
  - a **Settings** button that opens `UIApplication.openSettingsURLString`
    through the responder chain (allowed by 4.4.1; never `App-prefs:`).
    There's never an "Open Kallilex" button.
- **Keychain read failure without Full Access** (spike unknown 3): the runner
  degrades to "no key".
- **Network failures without Full Access** (spike unknown 4): every request fails at
  once with `NSPOSIXErrorDomain 1` ("Operation not permitted"), because the
  keyboard has no network without Full Access. Show the Full Access card instead of a network error whenever
  `hasFullAccess` is false and the error is `.http(status: 401 or 403, …)`,
  `NSPOSIXErrorDomain 1`, or the run had no key.
- **Copy** without Full Access: the Copy button shows a short note "Copy
  needs Full Access" instead of copying.

### Not configured

When no provider is active, the chips row shows "Set up a provider in the
Kallilex app." ("Richte in der Kallilex-App einen Anbieter ein."), as text
only. Typing still works.

## Testing Decisions

- **Unit tests** (`HostBridgeTests`, fake `TextDocument`):
  - take-over rules (empty Scratchpad; unchanged last selection; edited
    Scratchpad → chip);
  - Insert with a selection (replaced recorded) and without (nil);
  - the Insert label;
  - Undo allowed right after Insert;
  - Undo not allowed after another edit, after a cursor move, after 30 s
    (injected clock), or when the context doesn't end with the inserted
    text;
  - Undo deletes `Character`-count times and reinserts the original
    (emoji, `e\u{301}`, newline cases);
  - `invalidateUndo()`.
- **`KeyboardModel` tests:**
  - the Full Access card for a network profile without Full Access;
  - no card for the on-device profile when it's allowed;
  - the card instead of an auth error without a key and without Full Access;
  - consent flow through a stub `ConsentGranting`.
- **UI tests (harness):**
  - select a word in `harness.hostText`, switch the harness keyboard on, the
    Scratchpad shows the word;
  - run a prompt with the stub provider, **Replace selection**: the host text
    contains the stub result in place of the word;
  - **Undo** restores the word;
  - consent: a cloud profile with no consent shows the consent view;
    Allow runs the prompt.

  The harness gets a `-uiTestKeyboardNoFullAccess` argument that makes
  `hasFullAccess` report false. Without Full Access the card appears and
  typing still works.
- **Manual host-app matrix** (device): Notes, Mail, Messages, Safari (address
  bar, `<textarea>`, `contenteditable`), WhatsApp, Signal, Slack, Google Docs,
  Pages, Gmail, and a selection of about 3,000 characters. Per app:
  - is the selection taken over;
  - does Replace replace;
  - does Undo work.

  The results go into `issues-ios/release-ios-1.0.0-matrix.md`.

## Out of Scope

- Dictation (ios-21) and app setup (ios-22).
- Taking over the text before the cursor without a selection.
- A custom instruction typed in the keyboard.

## Further Notes

- PLAN-keyboard.md §4.2, §4.5, §7.2–7.4.
- `insertText` goes through the host's undo stack, so shake-to-undo in the
  host is the fallback for every case where our Undo is hidden.
