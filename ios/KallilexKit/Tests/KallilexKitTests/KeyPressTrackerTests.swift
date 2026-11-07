import Testing
import KallilexUI

/// Tests for `KeyPressTracker` (ios-18 rework): pure commit/rollover
/// bookkeeping, with plain `Int` touch identities standing in for
/// `KeyGridView`'s real `ObjectIdentifier(touch)`.
struct KeyPressTrackerTests {
    typealias Tracker = KeyPressTracker<Int>

    // ---- lift commits the key under the finger -----------------------------

    @Test func liftCommitsTheKeyUnderTheFinger() {
        var tracker = Tracker()
        tracker.beginTouch(1, at: 0, kind: .character)

        let commit = tracker.endTouch(1, cancelled: false)

        #expect(commit == .init(keyIndex: 0, alternateIndex: nil))
    }

    // ---- glide then lift commits the new key, nothing committed for the old ---

    @Test func glideThenLiftCommitsTheNewKey() {
        var tracker = Tracker()
        tracker.beginTouch(1, at: 0, kind: .character)

        // Sliding across keys before lift never itself produces a
        // commit — the old key's press is simply moved, not committed —
        // which is exactly what keeps `KeyboardState`'s shift from being
        // consumed twice (once for the old key, again for the new one).
        let movedDuringGlide = tracker.moveTouch(1, to: 2)
        #expect(movedDuringGlide)

        let commit = tracker.endTouch(1, cancelled: false)

        #expect(commit == .init(keyIndex: 2, alternateIndex: nil))
    }

    @Test func movingToTheSameKeyIsNotAMove() {
        var tracker = Tracker()
        tracker.beginTouch(1, at: 0, kind: .character)

        let moved = tracker.moveTouch(1, to: 0)
        #expect(!moved)
    }

    // ---- rollover: a second touch commits the first's in-progress press ----

    @Test func rolloverCommitsTheFirstPressWhenTheSecondBegins() {
        var tracker = Tracker()
        tracker.beginTouch(1, at: 0, kind: .character)

        let rollover = tracker.beginTouch(2, at: 5, kind: .character)
        #expect(rollover == .init(keyIndex: 0, alternateIndex: nil))

        // The first touch is no longer tracked (already committed); the
        // second now resolves independently.
        #expect(tracker.currentKeyIndex(for: 1) == nil)
        let secondCommit = tracker.endTouch(2, cancelled: false)
        #expect(secondCommit == .init(keyIndex: 5, alternateIndex: nil))
    }

    @Test func rolloverCommitsTheMovedKeyIfTheFirstPressHadGlided() {
        var tracker = Tracker()
        tracker.beginTouch(1, at: 0, kind: .character)
        tracker.moveTouch(1, to: 3)

        let rollover = tracker.beginTouch(2, at: 5, kind: .character)

        #expect(rollover == .init(keyIndex: 3, alternateIndex: nil))
    }

    // ---- rollover also triggered by an immediate new touch (space/delete/return) --

    @Test func anImmediateNewTouchAlsoCommitsTheEarlierCharacterPress() {
        var tracker = Tracker()
        tracker.beginTouch(1, at: 0, kind: .character)

        // Hitting space/delete/return while a letter is still down
        // commits that letter first, matching the system keyboard.
        let rollover = tracker.beginTouch(2, at: 9, kind: .immediate)

        #expect(rollover == .init(keyIndex: 0, alternateIndex: nil))
        #expect(tracker.currentKeyIndex(for: 1) == nil)
    }

    @Test func aDeferredNewTouchDoesNotCommitTheEarlierCharacterPress() {
        var tracker = Tracker()
        tracker.beginTouch(1, at: 0, kind: .character)

        // Shift/globe/layer-switch beginning never itself rolls over an
        // in-progress character press — only a `.character` or
        // `.immediate` new touch does.
        let rollover = tracker.beginTouch(2, at: 9, kind: .deferred)

        #expect(rollover == nil)
        #expect(tracker.currentKeyIndex(for: 1) == 0)
    }

    // ---- registerTouch is the non-rollover half of beginTouch -----------------

    @Test func takeRolloverCommitCommitsAndStopsTrackingTheInProgressCharacterPress() {
        var tracker = Tracker()
        tracker.beginTouch(1, at: 0, kind: .character)

        let commit = tracker.takeRolloverCommit()

        #expect(commit == .init(keyIndex: 0, alternateIndex: nil))
        #expect(tracker.currentKeyIndex(for: 1) == nil)
    }

    @Test func registerTouchNeverRollsOverAnInProgressCharacterPress() {
        var tracker = Tracker()
        tracker.beginTouch(1, at: 0, kind: .character)

        // Unlike `beginTouch`, `registerTouch` performs no rollover check
        // at all — callers that already applied `takeRolloverCommit()`
        // themselves (`KeyGridView`, after it may have rebuilt the grid)
        // use this instead so it isn't done a second time.
        tracker.registerTouch(2, at: 5, kind: .character)

        #expect(tracker.currentKeyIndex(for: 1) == 0)
        #expect(tracker.currentKeyIndex(for: 2) == 5)
    }

    // ---- an alternate selection commits exactly one insert ------------------

    @Test func alternateSelectionCommitsExactlyOneInsert() {
        var tracker = Tracker()
        tracker.beginTouch(1, at: 0, kind: .character)
        tracker.showAlternates(for: 1)
        tracker.selectAlternate(1, index: 2)

        let commit = tracker.endTouch(1, cancelled: false)

        #expect(commit == .init(keyIndex: 0, alternateIndex: 2))
        // Already removed — a second `endTouch` produces nothing further.
        let secondAttempt = tracker.endTouch(1, cancelled: false)
        #expect(secondAttempt == nil)
    }

    @Test func onceAlternatesAreShowingFurtherMovesDontRetarget() {
        var tracker = Tracker()
        tracker.beginTouch(1, at: 0, kind: .character)
        tracker.showAlternates(for: 1)

        let moved = tracker.moveTouch(1, to: 1)
        #expect(!moved)
        #expect(tracker.currentKeyIndex(for: 1) == 0)
    }

    // ---- cancel commits nothing ---------------------------------------------

    @Test func cancelCommitsNothing() {
        var tracker = Tracker()
        tracker.beginTouch(1, at: 0, kind: .character)

        let commit = tracker.endTouch(1, cancelled: true)

        #expect(commit == nil)
    }

    @Test func cancelAllStopsTrackingEveryTouchWithoutCommitting() {
        var tracker = Tracker()
        tracker.beginTouch(1, at: 0, kind: .character)
        tracker.beginTouch(2, at: 1, kind: .deferred)

        tracker.cancelAll()

        #expect(tracker.currentKeyIndex(for: 1) == nil)
        #expect(tracker.currentKeyIndex(for: 2) == nil)
        #expect(tracker.activeKeyIndices.isEmpty)
    }

    // ---- deferred keys (shift/globe/layer switch): lift-over-original only ----

    @Test func deferredKeyCommitsWhenLiftedOverItsOriginalKey() {
        var tracker = Tracker()
        tracker.beginTouch(1, at: 4, kind: .deferred)

        let commit = tracker.endTouch(1, cancelled: false)

        #expect(commit == .init(keyIndex: 4, alternateIndex: nil))
    }

    @Test func deferredKeyCancelsWhenLiftedAfterSlidingOff() {
        var tracker = Tracker()
        tracker.beginTouch(1, at: 4, kind: .deferred)
        tracker.updateDeferredPresence(1, isOverOriginalKey: false)

        let commit = tracker.endTouch(1, cancelled: false)

        #expect(commit == nil)
    }

    @Test func deferredKeyRecommitsIfTheFingerReturnsBeforeLift() {
        var tracker = Tracker()
        tracker.beginTouch(1, at: 4, kind: .deferred)
        tracker.updateDeferredPresence(1, isOverOriginalKey: false)
        tracker.updateDeferredPresence(1, isOverOriginalKey: true)

        let commit = tracker.endTouch(1, cancelled: false)

        #expect(commit == .init(keyIndex: 4, alternateIndex: nil))
    }

    @Test func deferredKeysAreNeverRetargetedByMoveTouch() {
        var tracker = Tracker()
        tracker.beginTouch(1, at: 4, kind: .deferred)

        let moved = tracker.moveTouch(1, to: 7)
        #expect(!moved)
        #expect(tracker.currentKeyIndex(for: 1) == 4)
    }

    @Test func deferredPressesAreNotRollOverEligible() {
        var tracker = Tracker()
        tracker.beginTouch(1, at: 4, kind: .deferred)

        let rollover = tracker.beginTouch(2, at: 5, kind: .character)

        #expect(rollover == nil)
        // The deferred press is untouched by the new touch beginning.
        #expect(tracker.currentKeyIndex(for: 1) == 4)
    }

    // ---- immediate keys (delete/space/return): already committed by the caller --

    @Test func immediateKeysNeverProduceACommitAtLift() {
        var tracker = Tracker()
        tracker.beginTouch(1, at: 9, kind: .immediate)

        let commit = tracker.endTouch(1, cancelled: false)

        #expect(commit == nil)
    }

    @Test func immediateKeysAreNotRollOverEligibleEither() {
        var tracker = Tracker()
        tracker.beginTouch(1, at: 9, kind: .immediate)

        let rollover = tracker.beginTouch(2, at: 5, kind: .character)

        #expect(rollover == nil)
    }

    // ---- activeKeyIndices --------------------------------------------------

    @Test func activeKeyIndicesReflectsEveryTrackedTouch() {
        var tracker = Tracker()
        tracker.beginTouch(1, at: 0, kind: .character)
        tracker.beginTouch(2, at: 3, kind: .deferred)

        #expect(tracker.activeKeyIndices == [0, 3])

        tracker.moveTouch(1, to: 2)
        #expect(tracker.activeKeyIndices == [2, 3])
    }
}
