//! Synthetic Ctrl+C/Ctrl+V input synthesis via the
//! `org.freedesktop.portal.RemoteDesktop` portal (spec-12 Slice C).
//!
//! Three concerns, kept in separate layers so the orchestration — the part
//! that actually has interesting logic — is unit-testable without a real
//! portal or D-Bus connection:
//!
//! 1. [`chord_events`]: a pure function producing the press/release keycode
//!    sequence for a Ctrl+C/Ctrl+V chord. No ashpd types involved, so it's
//!    trivially unit-tested.
//! 2. [`RemoteDesktopBackend`] + [`ensure_session_and_send_chord`]: the
//!    session/restore-token lifecycle and chord-sending orchestration,
//!    generic over the backend trait so it can run against a fake in tests
//!    and against [`AshpdBackend`] in production.
//! 3. [`AshpdBackend`]: the real portal calls, plus the process-wide
//!    [`send_chord`] entry point that lazily starts a single manager task
//!    owning the one live session (see that function's doc comment for the
//!    threading rationale), and [`drop_session`] (spec-13 Slice A), which
//!    tells that same manager to release the session without starting one
//!    that didn't already exist.
//!
//! **Keycode caveat (accepted for v1):** `NotifyKeyboardKeycode` takes Linux
//! evdev keycodes, which are *positional* (they identify a physical key,
//! not a character) — on non-QWERTY layouts where the keys physically in
//! the C/V positions produce different characters, this can mistype. A
//! keymap-aware lookup (translating the character to whatever keycode the
//! active layout actually maps it to) is an explicit follow-up, out of
//! scope for this spec. This is the same class of caveat `LinuxKeyboard`'s
//! X11/enigo path has historically accepted for non-`Key::Unicode` input,
//! just via a different mechanism.

use std::sync::OnceLock;

use tokio::sync::mpsc;

use ashpd::desktop::remote_desktop::{
    DeviceType, KeyState, NotifyKeyboardKeycodeOptions, RemoteDesktop, SelectDevicesOptions,
    StartOptions,
};
use ashpd::desktop::{CreateSessionOptions, PersistMode};
use ashpd::enumflags2::BitFlags;

use crate::core::settings::{self, SettingsStore, TauriStoreSettings};

/// Linux evdev keycode for the left Control key.
const KEY_LEFTCTRL: i32 = 29;
/// Linux evdev keycode for the `C` key (QWERTY position — see the module
/// doc comment's keycode caveat).
const KEY_C: i32 = 46;
/// Linux evdev keycode for the `V` key (QWERTY position — see the module
/// doc comment's keycode caveat).
const KEY_V: i32 = 47;

/// Which synthetic chord to send.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Chord {
    /// Ctrl+C.
    Copy,
    /// Ctrl+V.
    Paste,
}

/// A single step of a chord: pressing or releasing one key. Kept free of
/// ashpd's [`KeyState`] so [`chord_events`] stays a plain, dependency-free
/// pure function to unit-test; callers map this to `KeyState` themselves
/// (see [`send_chord_events`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum KeyAction {
    Press,
    Release,
}

/// Produces the four-event press/release sequence for a Ctrl+`key` chord:
/// Control down, key down, key up, Control up. Control is always the first
/// event pressed and the last event released, matching real chorded-key
/// input and mirroring the ordering guarantee `LinuxKeyboard`'s X11/enigo
/// path already makes.
fn chord_events(chord: Chord) -> [(i32, KeyAction); 4] {
    let key = match chord {
        Chord::Copy => KEY_C,
        Chord::Paste => KEY_V,
    };
    [
        (KEY_LEFTCTRL, KeyAction::Press),
        (key, KeyAction::Press),
        (key, KeyAction::Release),
        (KEY_LEFTCTRL, KeyAction::Release),
    ]
}

/// Seam for the actual portal I/O, so [`ensure_session_and_send_chord`] can
/// be unit-tested against a fake instead of a real D-Bus/portal round trip.
/// Private to this module: no other part of the codebase needs to see
/// portal internals.
trait RemoteDesktopBackend {
    /// An established, live RemoteDesktop session capable of sending key
    /// events. Opaque to the orchestration logic.
    type Session;

    /// Creates a session, selects the `KEYBOARD` device, and starts it —
    /// the full sequence a fresh session needs before `send_key` will do
    /// anything. `restore_token` is passed straight through to the portal
    /// (only meaningful when persistence is supported; see
    /// [`AshpdBackend::start_session`]). Returns the live session plus
    /// whatever restore token the portal issued for *this* session (`None`
    /// if it issued none, e.g. no persistence support or the compositor
    /// declined to persist).
    async fn start_session(
        &self,
        restore_token: Option<String>,
    ) -> Result<(Self::Session, Option<String>), String>;

    /// Whether this backend is able to persist a session across restarts at
    /// all (i.e. whether a restore token it is given will ever actually be
    /// honored, and whether a token it returns is ever meaningful). Lets
    /// [`establish_session`] know, independent of any single call's outcome,
    /// whether it's even worth reading/writing the stored token — see that
    /// function's doc comment for how this is used.
    fn supports_persistence(&self) -> bool;

    /// Sends a single keyboard keycode event: `press == true` for key-down,
    /// `false` for key-up.
    async fn send_key(
        &self,
        session: &Self::Session,
        keycode: i32,
        press: bool,
    ) -> Result<(), String>;
}

/// The orchestration heart of this module: given a (possibly already-live)
/// session, a backend, and the settings store, makes sure a session exists
/// (establishing/re-establishing one per the restore-token lifecycle
/// documented on [`establish_session`]) and then sends `chord` over it.
///
/// `session` is the manager's single owned slot ([`super::run_manager`]
/// holds the only instance) — reused across calls when already `Some`, so a
/// session (and its permission grant) is only ever created on first use,
/// never per-call. If sending the chord fails, the session is dropped
/// (`*session = None`) so the *next* call re-establishes fresh rather than
/// silently reusing what might now be a broken session.
async fn ensure_session_and_send_chord<B: RemoteDesktopBackend>(
    backend: &B,
    session: &mut Option<B::Session>,
    store: &dyn SettingsStore,
    chord: Chord,
) -> Result<(), String> {
    if session.is_none() {
        *session = Some(establish_session(backend, store).await?);
    }

    // `session` was just guaranteed `Some` above (either it already was, or
    // `establish_session` returned early on `Err` without ever getting
    // here), so this is a live reference, not a fresh unwrap risk.
    let live_session = session
        .as_ref()
        .expect("session was just established or already live");

    if let Err(err) = send_chord_events(backend, live_session, chord).await {
        *session = None;
        return Err(err);
    }

    Ok(())
}

/// Establishes a live session, implementing the restore-token lifecycle:
///
/// - If the backend doesn't [support persistence at
///   all](RemoteDesktopBackend::supports_persistence), the stored token is
///   treated as absent from the very start: it is neither loaded/passed nor
///   read again below, and a failure is final with no retry (that falls out
///   naturally from `stored_token` being `None`) — a stale token sitting in
///   settings is simply left untouched (it's inert; nothing ever reads it
///   back into this flow while persistence is unsupported).
/// - Otherwise, loads the stored restore token (if any) and passes it to
///   [`RemoteDesktopBackend::start_session`].
/// - On success: `ashpd` models even a successful `Start` response's restore
///   token as optional (some backends don't re-echo it on a successful
///   reuse), so a `None` here must *not* be read as "clear the stored
///   token" — only an explicitly-returned token that differs from what was
///   stored gets persisted. Clearing a token is exclusively the failure
///   path's job, below.
/// - On failure *with* a stored token: the token is presumed stale/revoked
///   — clears it (persisting the clear) and retries exactly once with no
///   token at all, which lets the portal re-prompt the user normally. A
///   second failure is returned as-is; there is no further retry. (Known
///   limitation: `ashpd::Error` is flattened to a `String` at this seam, so
///   a user *declining* the fresh dialog is indistinguishable here from a
///   genuinely revoked/stale token, and both take this same clearing path —
///   conservative and fail-safe, since the only consequence is the next
///   attempt re-prompting; a structured error distinction is a possible
///   follow-up.)
/// - On failure *without* a stored token: returned as-is immediately, no
///   retry (there is nothing left to change about the request).
async fn establish_session<B: RemoteDesktopBackend>(
    backend: &B,
    store: &dyn SettingsStore,
) -> Result<B::Session, String> {
    let stored_token = if backend.supports_persistence() {
        settings::get_settings(store)
            .map_err(|e| e.to_string())?
            .wayland_restore_token
    } else {
        None
    };

    match backend.start_session(stored_token.clone()).await {
        Ok((session, new_token)) => {
            if let Some(token) = new_token {
                if stored_token.as_deref() != Some(token.as_str()) {
                    persist_token(store, Some(token))?;
                }
            }
            Ok(session)
        }
        Err(err) => {
            if stored_token.is_none() {
                return Err(err);
            }

            persist_token(store, None)?;
            let (session, new_token) = backend.start_session(None).await?;
            if new_token.is_some() {
                persist_token(store, new_token)?;
            }
            Ok(session)
        }
    }
}

/// Loads, mutates, and re-saves the whole [`settings::Settings`] value with
/// a new `wayland_restore_token` — the store only exposes whole-value
/// load/save, so every field write goes through this load-modify-save
/// pattern.
fn persist_token(store: &dyn SettingsStore, token: Option<String>) -> Result<(), String> {
    let mut current = settings::get_settings(store).map_err(|e| e.to_string())?;
    current.wayland_restore_token = token;
    settings::set_settings(store, current)
        .map(|_| ())
        .map_err(|e| e.to_string())
}

/// Sends every event of `chord`'s sequence over `session`, unconditionally
/// — even after an earlier event in the sequence fails, later events
/// (crucially, the Release events) are still attempted, so Ctrl (and the
/// chord key) are never left logically held down system-wide on a
/// best-effort basis. Returns the *first* error encountered, if any.
async fn send_chord_events<B: RemoteDesktopBackend>(
    backend: &B,
    session: &B::Session,
    chord: Chord,
) -> Result<(), String> {
    let mut first_error: Option<String> = None;

    for (keycode, action) in chord_events(chord) {
        let press = action == KeyAction::Press;
        if let Err(err) = backend.send_key(session, keycode, press).await {
            first_error.get_or_insert(err);
        }
    }

    match first_error {
        Some(err) => Err(err),
        None => Ok(()),
    }
}

/// A live RemoteDesktop portal session plus the proxy that created it, kept
/// together so [`AshpdBackend::send_key`] doesn't need to reconnect to the
/// portal service for every single keystroke.
struct AshpdSession {
    proxy: RemoteDesktop,
    session: ashpd::desktop::Session<RemoteDesktop>,
}

/// The real [`RemoteDesktopBackend`], calling the `RemoteDesktop` portal via
/// ashpd.
struct AshpdBackend;

impl RemoteDesktopBackend for AshpdBackend {
    type Session = AshpdSession;

    /// `CreateSession` -> `SelectDevices(KEYBOARD)` -> `Start`. Persistence
    /// (`persist_mode`/`restore_token`) is only ever requested when
    /// [`super::capabilities`] reports `can_persist_session` — on an older
    /// `RemoteDesktop` v1 backend, passing a restore token or a non-`DoNot`
    /// persist mode is simply not meaningful, so neither is sent. Callers
    /// don't need to duplicate this check themselves: when persistence is
    /// unsupported, [`Self::supports_persistence`] tells
    /// [`establish_session`] not to pass a token in the first place (it
    /// passes `None` here as `restore_token`), so this only ever forces the
    /// *persist mode* to `DoNot` — there is no token to force away.
    async fn start_session(
        &self,
        restore_token: Option<String>,
    ) -> Result<(Self::Session, Option<String>), String> {
        let proxy = RemoteDesktop::new().await.map_err(|e| e.to_string())?;

        let session = proxy
            .create_session(CreateSessionOptions::default())
            .await
            .map_err(|e| e.to_string())?;

        let persist_mode = if self.supports_persistence() {
            PersistMode::ExplicitlyRevoked
        } else {
            PersistMode::DoNot
        };

        let mut select_options = SelectDevicesOptions::default()
            .set_devices(BitFlags::from(DeviceType::Keyboard))
            .set_persist_mode(persist_mode);
        if let Some(token) = restore_token.as_deref() {
            select_options = select_options.set_restore_token(token);
        }

        proxy
            .select_devices(&session, select_options)
            .await
            .map_err(|e| e.to_string())?
            .response()
            .map_err(|e| e.to_string())?;

        let selected = proxy
            .start(&session, None, StartOptions::default())
            .await
            .map_err(|e| e.to_string())?
            .response()
            .map_err(|e| e.to_string())?;

        let new_token = selected.restore_token().map(str::to_string);

        Ok((AshpdSession { proxy, session }, new_token))
    }

    fn supports_persistence(&self) -> bool {
        super::capabilities().can_persist_session
    }

    async fn send_key(
        &self,
        session: &Self::Session,
        keycode: i32,
        press: bool,
    ) -> Result<(), String> {
        let state = if press {
            KeyState::Pressed
        } else {
            KeyState::Released
        };
        session
            .proxy
            .notify_keyboard_keycode(
                &session.session,
                keycode,
                state,
                NotifyKeyboardKeycodeOptions::default(),
            )
            .await
            .map_err(|e| e.to_string())
    }
}

/// A single message routed through the manager task's request channel:
/// either "send this chord" (spec-12) or "drop the live session" (spec-13
/// Slice A, the input-synthesis opt-out).
enum ManagerMessage {
    /// Send `chord`, replying exactly once with the outcome. Preserving
    /// "exactly one reply per `SendChord`" is what makes [`send_chord`]'s
    /// blocking `recv()` safe — see that function's doc comment.
    SendChord {
        chord: Chord,
        reply: std::sync::mpsc::Sender<Result<(), String>>,
    },
    /// Drop the manager's live session (if any), releasing its portal
    /// resources. No reply: [`drop_session`] is fire-and-forget, since there
    /// is nothing meaningful to report back and no caller waits on it.
    DropSession,
}

/// Process-wide handle to the manager task's request channel, lazily
/// created by the first [`send_chord`] call. See [`send_chord`]'s doc
/// comment for why the manager — and, transitively, the portal session
/// itself — is started on first use rather than at startup.
static MANAGER: OnceLock<mpsc::UnboundedSender<ManagerMessage>> = OnceLock::new();

/// Returns the manager task's request sender, spawning the manager the
/// first time this is called — on its own dedicated OS thread (via
/// `std::thread::spawn` + `tauri::async_runtime::block_on`), capturing a
/// clone of `app`. See [`send_chord`]'s doc comment for why a dedicated
/// thread, rather than `tauri::async_runtime::spawn` onto the shared tokio
/// pool, is required here.
fn manager_sender(app: &tauri::AppHandle) -> mpsc::UnboundedSender<ManagerMessage> {
    MANAGER
        .get_or_init(|| {
            let (tx, rx) = mpsc::unbounded_channel();
            let app = app.clone();
            std::thread::Builder::new()
                .name("wayland-remote-desktop-manager".to_string())
                .spawn(move || tauri::async_runtime::block_on(run_manager(app, rx)))
                .expect("failed to spawn the Wayland input-synthesis manager thread");
            tx
        })
        .clone()
}

/// The manager task body: owns the one live [`AshpdSession`] (if any) and a
/// [`TauriStoreSettings`] handle, and processes messages strictly
/// sequentially from a single-consumer channel — that alone serializes all
/// portal access, so no additional locking is needed anywhere in this
/// module. Runs for the lifetime of the app; the loop only ends if every
/// [`mpsc::UnboundedSender`] clone (held by past/future [`send_chord`]/
/// [`drop_session`] calls) has been dropped, which in practice never happens
/// before process exit.
async fn run_manager(app: tauri::AppHandle, mut requests: mpsc::UnboundedReceiver<ManagerMessage>) {
    let backend = AshpdBackend;
    let store = TauriStoreSettings::new(app);
    let mut session: Option<AshpdSession> = None;

    while let Some(message) = requests.recv().await {
        match message {
            ManagerMessage::SendChord { chord, reply } => {
                let result =
                    ensure_session_and_send_chord(&backend, &mut session, &store, chord).await;
                let _ = reply.send(result);
            }
            ManagerMessage::DropSession => {
                session = None;
            }
        }
    }
}

/// Drops the manager's live RemoteDesktop session (if any), so Kallilex
/// never sits holding an open remote-input session it has decided not to
/// use (spec-13 Slice A, called when the user switches input synthesis
/// off). Deliberately never spawns the manager: a manager that was never
/// created has no session to drop, so starting one here just to immediately
/// idle it would be pure overhead with no observable effect. Send failure
/// (the manager thread having died) is ignored — there's nothing left to
/// clean up on this side either way.
pub fn drop_session() {
    if let Some(sender) = MANAGER.get() {
        let _ = sender.send(ManagerMessage::DropSession);
    }
}

/// Sends a synthetic Ctrl+C/Ctrl+V chord through the process-wide
/// RemoteDesktop portal session, establishing (or re-establishing) the
/// session on demand.
///
/// **Why the session is created on first use, not at startup:** the very
/// first `start_session` call is exactly where the portal's permission
/// dialog can appear (an unprivileged app has no RemoteDesktop access until
/// the user grants it), and that dialog should only ever appear as the
/// direct consequence of a user-initiated action — the user's first
/// fallback-copy or Replace — never as a surprise during app launch. The
/// manager task itself is spawned lazily too ([`manager_sender`]), but that
/// alone creates no session: [`run_manager`]'s `session` slot starts `None`
/// and is only populated once an actual request arrives.
///
/// **Why blocking on `reply_rx.recv()` here is safe:** this function is
/// never called from Tauri's main thread — its only callers are
/// `LinuxKeyboard::send_copy`/`send_paste`, invoked from capture's
/// spawn_blocking/shortcut-handler threads and from the `replace_back`
/// async command running on a tokio worker thread. Blocking a tokio worker
/// thread briefly is already an accepted pattern in this codebase (the
/// `StdSleeper`-based settle delays in `core::replace` do the same). What
/// makes this specific blocking call safe, though, isn't just "a different
/// worker thread" — it's that the manager ([`run_manager`], driven from
/// [`manager_sender`]) runs on its own **dedicated OS thread**, entirely
/// outside Tauri's shared multi-thread tokio pool, so no shared-executor
/// circular wait can exist regardless of how many workers that pool has
/// (including exactly one, e.g. on a 1-vCPU machine — a blocked caller on
/// the shared pool could otherwise starve the manager forever if it also
/// lived on that pool). The manager always sends exactly one reply per
/// request (there is no early-return path in `run_manager`'s loop that
/// skips the reply), so this can only block for the duration of one portal
/// round trip. No timeout is layered on top: if the manager task has died
/// outright, `reply` is dropped without sending and `recv()` returns an
/// error immediately rather than hanging, which is mapped to `Err` below.
///
/// A nested-runtime panic (`block_on` inside an async context) can never
/// happen here: nothing in this call chain calls `block_on` anywhere —
/// `reply_rx.recv()` is `std::sync::mpsc::Receiver::recv`, an ordinary
/// blocking call, not a runtime entry point.
pub fn send_chord(app: &tauri::AppHandle, chord: Chord) -> Result<(), String> {
    let sender = manager_sender(app);
    let (reply_tx, reply_rx) = std::sync::mpsc::channel();

    sender
        .send(ManagerMessage::SendChord {
            chord,
            reply: reply_tx,
        })
        .map_err(|_| {
            "the Wayland input-synthesis session manager is no longer running".to_string()
        })?;

    reply_rx.recv().map_err(|_| {
        "the Wayland input-synthesis session manager stopped without replying".to_string()
    })?
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;
    use crate::core::settings::InMemorySettingsStore;

    #[test]
    fn copy_chord_is_ctrl_then_c_press_release_then_ctrl_release() {
        assert_eq!(
            chord_events(Chord::Copy),
            [
                (KEY_LEFTCTRL, KeyAction::Press),
                (KEY_C, KeyAction::Press),
                (KEY_C, KeyAction::Release),
                (KEY_LEFTCTRL, KeyAction::Release),
            ]
        );
    }

    #[test]
    fn paste_chord_is_ctrl_then_v_press_release_then_ctrl_release() {
        assert_eq!(
            chord_events(Chord::Paste),
            [
                (KEY_LEFTCTRL, KeyAction::Press),
                (KEY_V, KeyAction::Press),
                (KEY_V, KeyAction::Release),
                (KEY_LEFTCTRL, KeyAction::Release),
            ]
        );
    }

    #[test]
    fn ctrl_is_always_first_pressed_and_last_released() {
        for chord in [Chord::Copy, Chord::Paste] {
            let events = chord_events(chord);
            assert_eq!(events.first(), Some(&(KEY_LEFTCTRL, KeyAction::Press)));
            assert_eq!(events.last(), Some(&(KEY_LEFTCTRL, KeyAction::Release)));
        }
    }

    /// One queued `start_session` outcome: the fake session id plus the
    /// restore token the fake portal "issues" on success, or an error.
    type StartOutcome = Result<(u32, Option<String>), String>;

    /// A configurable fake [`RemoteDesktopBackend`] for orchestration tests:
    /// `start_session` returns one queued outcome per call (panicking if
    /// called more often than configured, which would itself indicate a
    /// test bug), and `send_key` fails for exactly the calls whose index is
    /// listed in `failing_send_key_indices`.
    struct FakeBackend {
        start_outcomes: Mutex<Vec<StartOutcome>>,
        start_calls: Mutex<Vec<Option<String>>>,
        failing_send_key_indices: Vec<usize>,
        send_key_calls: Mutex<Vec<(i32, bool)>>,
        supports_persistence: bool,
    }

    impl FakeBackend {
        fn new(start_outcomes: Vec<StartOutcome>) -> Self {
            Self {
                start_outcomes: Mutex::new(start_outcomes),
                start_calls: Mutex::new(Vec::new()),
                failing_send_key_indices: Vec::new(),
                send_key_calls: Mutex::new(Vec::new()),
                supports_persistence: true,
            }
        }

        fn failing_send_key_at(mut self, indices: Vec<usize>) -> Self {
            self.failing_send_key_indices = indices;
            self
        }

        fn with_supports_persistence(mut self, supports_persistence: bool) -> Self {
            self.supports_persistence = supports_persistence;
            self
        }

        fn start_calls(&self) -> Vec<Option<String>> {
            self.start_calls.lock().unwrap().clone()
        }

        fn send_key_call_count(&self) -> usize {
            self.send_key_calls.lock().unwrap().len()
        }
    }

    impl RemoteDesktopBackend for FakeBackend {
        type Session = u32;

        async fn start_session(
            &self,
            restore_token: Option<String>,
        ) -> Result<(u32, Option<String>), String> {
            self.start_calls.lock().unwrap().push(restore_token);
            let mut outcomes = self.start_outcomes.lock().unwrap();
            if outcomes.is_empty() {
                panic!("FakeBackend::start_session called more times than configured");
            }
            outcomes.remove(0)
        }

        fn supports_persistence(&self) -> bool {
            self.supports_persistence
        }

        async fn send_key(&self, _session: &u32, keycode: i32, press: bool) -> Result<(), String> {
            let mut calls = self.send_key_calls.lock().unwrap();
            let index = calls.len();
            calls.push((keycode, press));
            if self.failing_send_key_indices.contains(&index) {
                Err("send_key failed".to_string())
            } else {
                Ok(())
            }
        }
    }

    #[tokio::test]
    async fn token_is_stored_on_first_grant() {
        let backend = FakeBackend::new(vec![Ok((1, Some("tok1".to_string())))]);
        let store = InMemorySettingsStore::new();
        let mut session: Option<u32> = None;

        let result =
            ensure_session_and_send_chord(&backend, &mut session, &store, Chord::Copy).await;

        assert!(result.is_ok());
        assert_eq!(
            settings::get_settings(&store)
                .unwrap()
                .wayland_restore_token,
            Some("tok1".to_string())
        );
    }

    #[tokio::test]
    async fn stored_token_is_passed_on_the_next_session_creation() {
        let backend = FakeBackend::new(vec![
            Ok((1, Some("tok1".to_string()))),
            Ok((2, Some("tok1".to_string()))),
        ]);
        let store = InMemorySettingsStore::new();
        let mut session: Option<u32> = None;

        ensure_session_and_send_chord(&backend, &mut session, &store, Chord::Copy)
            .await
            .unwrap();

        // Force re-establishment (mirrors a chord failure dropping the
        // session) rather than reusing the live one, so the second
        // `start_session` call actually happens.
        session = None;
        ensure_session_and_send_chord(&backend, &mut session, &store, Chord::Copy)
            .await
            .unwrap();

        assert_eq!(backend.start_calls(), vec![None, Some("tok1".to_string())]);
    }

    #[tokio::test]
    async fn a_live_session_is_reused_without_calling_start_session_again() {
        let backend = FakeBackend::new(vec![Ok((1, None))]);
        let store = InMemorySettingsStore::new();
        let mut session: Option<u32> = None;

        ensure_session_and_send_chord(&backend, &mut session, &store, Chord::Copy)
            .await
            .unwrap();
        ensure_session_and_send_chord(&backend, &mut session, &store, Chord::Paste)
            .await
            .unwrap();

        assert_eq!(backend.start_calls(), vec![None]);
        // Two chords, four events each.
        assert_eq!(backend.send_key_call_count(), 8);
    }

    #[tokio::test]
    async fn invalid_token_is_cleared_and_retried_once_without_it() {
        let backend = FakeBackend::new(vec![
            Err("revoked".to_string()),
            Ok((1, Some("tok2".to_string()))),
        ]);
        let store = InMemorySettingsStore::new();
        {
            let mut settings = settings::get_settings(&store).unwrap();
            settings.wayland_restore_token = Some("stale-token".to_string());
            settings::set_settings(&store, settings).unwrap();
        }
        let mut session: Option<u32> = None;

        let result =
            ensure_session_and_send_chord(&backend, &mut session, &store, Chord::Copy).await;

        assert!(result.is_ok());
        assert_eq!(
            backend.start_calls(),
            vec![Some("stale-token".to_string()), None]
        );
        assert_eq!(
            settings::get_settings(&store)
                .unwrap()
                .wayland_restore_token,
            Some("tok2".to_string())
        );
    }

    #[tokio::test]
    async fn a_second_failure_on_the_retry_is_the_final_error() {
        let backend = FakeBackend::new(vec![
            Err("revoked".to_string()),
            Err("still revoked".to_string()),
        ]);
        let store = InMemorySettingsStore::new();
        {
            let mut settings = settings::get_settings(&store).unwrap();
            settings.wayland_restore_token = Some("stale-token".to_string());
            settings::set_settings(&store, settings).unwrap();
        }
        let mut session: Option<u32> = None;

        let result =
            ensure_session_and_send_chord(&backend, &mut session, &store, Chord::Copy).await;

        assert_eq!(result, Err("still revoked".to_string()));
        assert_eq!(
            settings::get_settings(&store)
                .unwrap()
                .wayland_restore_token,
            None
        );
    }

    #[tokio::test]
    async fn failure_without_a_stored_token_is_the_final_error_with_no_retry() {
        let backend = FakeBackend::new(vec![Err("declined".to_string())]);
        let store = InMemorySettingsStore::new();
        let mut session: Option<u32> = None;

        let result =
            ensure_session_and_send_chord(&backend, &mut session, &store, Chord::Copy).await;

        assert_eq!(result, Err("declined".to_string()));
        assert_eq!(backend.start_calls(), vec![None]);
    }

    #[tokio::test]
    async fn success_with_no_returned_token_stores_nothing() {
        let backend = FakeBackend::new(vec![Ok((1, None))]);
        let store = InMemorySettingsStore::new();
        let mut session: Option<u32> = None;

        ensure_session_and_send_chord(&backend, &mut session, &store, Chord::Copy)
            .await
            .unwrap();

        assert_eq!(
            settings::get_settings(&store)
                .unwrap()
                .wayland_restore_token,
            None
        );
    }

    #[tokio::test]
    async fn a_chord_send_failure_drops_the_session_and_the_next_call_re_establishes() {
        let backend = FakeBackend::new(vec![Ok((1, None)), Ok((2, None))])
            // Fail the second event (index 1) of the first chord's four
            // events — enough to make `send_chord_events` report an error
            // while still exercising "later events are still attempted".
            .failing_send_key_at(vec![1]);
        let store = InMemorySettingsStore::new();
        let mut session: Option<u32> = None;

        let first =
            ensure_session_and_send_chord(&backend, &mut session, &store, Chord::Copy).await;
        assert!(first.is_err());
        assert!(session.is_none());
        // All four events of the failed chord were still attempted despite
        // the failure at index 1.
        assert_eq!(backend.send_key_call_count(), 4);

        let second =
            ensure_session_and_send_chord(&backend, &mut session, &store, Chord::Copy).await;
        assert!(second.is_ok());
        assert_eq!(backend.start_calls().len(), 2);
    }

    #[tokio::test]
    async fn success_with_no_returned_token_does_not_clear_an_existing_stored_token() {
        let backend = FakeBackend::new(vec![Ok((1, None))]);
        let store = InMemorySettingsStore::new();
        {
            let mut settings = settings::get_settings(&store).unwrap();
            settings.wayland_restore_token = Some("tok1".to_string());
            settings::set_settings(&store, settings).unwrap();
        }
        let mut session: Option<u32> = None;

        let result =
            ensure_session_and_send_chord(&backend, &mut session, &store, Chord::Copy).await;

        assert!(result.is_ok());
        assert_eq!(
            settings::get_settings(&store)
                .unwrap()
                .wayland_restore_token,
            Some("tok1".to_string())
        );
    }

    #[tokio::test]
    async fn persistence_unsupported_never_passes_or_clears_the_stored_token() {
        let backend =
            FakeBackend::new(vec![Err("declined".to_string())]).with_supports_persistence(false);
        let store = InMemorySettingsStore::new();
        {
            let mut settings = settings::get_settings(&store).unwrap();
            settings.wayland_restore_token = Some("tok1".to_string());
            settings::set_settings(&store, settings).unwrap();
        }
        let mut session: Option<u32> = None;

        let result =
            ensure_session_and_send_chord(&backend, &mut session, &store, Chord::Copy).await;

        assert_eq!(result, Err("declined".to_string()));
        // Exactly one call, with no token passed — no retry, since an
        // unsupported-persistence backend has nothing left to change about
        // the request (the stored token was never part of it).
        assert_eq!(backend.start_calls(), vec![None]);
        assert_eq!(
            settings::get_settings(&store)
                .unwrap()
                .wayland_restore_token,
            Some("tok1".to_string())
        );
    }
}
