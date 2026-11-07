import UIKit
import KallilexKeyboardCore

/// The UIKit key grid (ios-18, PLAN-keyboard.md §6.1): draws keys with
/// `CALayer`s — a rounded-rect background plus a `CATextLayer` label per
/// key, no `UIButton`s — and does its own hit testing from
/// `KeyboardLayout.rows`, driven by the given `KeyboardModel`. A touch
/// always lands on the nearest key in its row (clamped to the nearest row
/// vertically), including touches in the gaps between keys, so there are
/// no dead zones.
///
/// All commit/rollover decisions are delegated to `KeyPressTracker`
/// (keyed per `UITouch` via `ObjectIdentifier`), which this view only
/// feeds key indices and reads `Commit`s back from — see that type's doc
/// comment for the full behavior: character keys commit on lift (to
/// whichever key ends up under the finger, or to a selected alternate),
/// never speculatively on touch-down, so shift/double-space state and
/// the host's own undo stack only ever see the edit the user actually
/// produces; shift/globe/the layer keys commit on lift only if the
/// finger is still over their own key; delete/space/return commit
/// immediately. Two simultaneous touches roll over correctly (an earlier
/// character press commits the moment a second one begins).
///
/// A long-press (0.4 s) on a character key with alternates shows them;
/// sliding onto one selects it (lifting then commits it instead of the
/// key's default). Before that fires, sliding onto a different key moves
/// the press and the popup there — purely visual, no edit happens until
/// lift. The delete key repeats via a `Timer` calling
/// `KeyboardModel.deleteRepeatTick(heldFor:)` on a ~0.05 s tick (matching
/// `KeyboardState.deleteRepeatEdit`'s documented contract) for as long as
/// the finger stays on it. The globe key forwards every touch phase live
/// to `onGlobeTouch`, which the controller wires to
/// `handleInputModeList(from:with:)` — the same thing a `UIControl`'s
/// `.allTouchEvents` action would see, so a long-press there still shows
/// the system's input-mode list. `cancelActivePress()` tears down every
/// in-progress press (timers, popups, highlights) without committing
/// anything — call it when the keyboard is about to disappear. No
/// haptics or input clicks (ios-15 spike, unknown 15: neither worked in
/// the spike, and they're not needed for the main flow).
@MainActor
public final class KeyGridView: UIView {
    /// Supplies the `KeyboardContext` for the currently active document:
    /// the Scratchpad always reports `.sentences`, the host app reports
    /// whatever `textDocumentProxy.autocapitalizationType` says. Built by
    /// the controller, since `KallilexKeyboardCore.TextDocument` alone
    /// doesn't carry that information.
    public var buildContext: () -> KeyboardContext = { KeyboardContext(autocapitalization: .sentences) }
    /// The Return key's label: from `textDocumentProxy.returnKeyType`
    /// when typing into the host app, always "return" for the Scratchpad.
    public var returnKeyLabel: () -> String = { "return" }
    /// Forwards every touch phase on the globe key to the controller.
    public var onGlobeTouch: ((UIView, UIEvent) -> Void)?
    public var showsGlobe = false {
        didSet { if showsGlobe != oldValue { rebuildLayers() } }
    }
    public var layoutID: KeyboardLayoutID = .qwerty {
        didSet { if layoutID != oldValue { rebuildLayers() } }
    }
    public var keyboardAppearance: UIKeyboardAppearance = .default {
        didSet { if keyboardAppearance != oldValue { updateColors() } }
    }

    private let model: KeyboardModel

    private var rows: [[Key]] = []
    private var keyLayers: [KeyLayerInfo] = []

    private var tracker = KeyPressTracker<ObjectIdentifier>()
    private var lastHighlightedIndices: Set<Int> = []
    private var longPressTimers: [ObjectIdentifier: Timer] = [:]
    private var deleteRepeatTimers: [ObjectIdentifier: Timer] = [:]
    private var deleteRepeatStarts: [ObjectIdentifier: Date] = [:]
    private var calloutLayers: [ObjectIdentifier: CALayer] = [:]
    private var alternatesLayers: [ObjectIdentifier: CALayer] = [:]
    /// Each active touch's last-known location in this view's coordinate
    /// space — set in `touchesBegan`/`touchesMoved`, removed in
    /// `cleanUpTouch`/`cancelActivePress`. Lets `refreshLabels()`'s
    /// layer-switch remap resolve which key each still-down touch now
    /// lands on after the grid is rebuilt, without needing a live
    /// `UITouch` (which `touchesBegan`'s own point is also captured from,
    /// to avoid re-deriving it from a possibly-stale `UITouch` later).
    private var touchPoints: [ObjectIdentifier: CGPoint] = [:]

    private struct KeyLayerInfo {
        let key: Key
        let name: String
        var frame: CGRect = .zero
        let background: CALayer
        let text: CATextLayer
        /// The string last assigned to `text.string` — lets
        /// `updateLabelsText()` skip re-setting (and re-rasterizing) a
        /// `CATextLayer` whose label hasn't actually changed.
        var lastDisplayText: String?
    }

    /// The accessibility elements built by `buildAccessibilityElements()`,
    /// parallel to `keyLayers` by index — kept around so `refreshLabels()`
    /// can update an element's `accessibilityLabel` in place on a shift/
    /// caps-lock change instead of rebuilding the whole array (which would
    /// also have to happen on every keystroke).
    private var accessibilityElementsList: [UIAccessibilityElement] = []

    /// The `bounds.size` `layoutKeyLayers()` last computed frames for —
    /// together with `needsKeyLayout`, lets `layoutSubviews()` skip
    /// relaying out ~33 key frames (and rebuilding accessibility elements)
    /// on every call; only a real size change or `rebuildLayers()` needs it.
    private var lastLaidOutSize: CGSize = .zero
    /// The `KeyboardState.layer` the current `rows`/`keyLayers` were built
    /// for — `refreshLabels()` rebuilds the grid when the model's layer
    /// no longer matches it.
    private var shownLayer: KeyboardLayer = .letters
    private var needsKeyLayout = true

    public init(model: KeyboardModel) {
        self.model = model
        super.init(frame: .zero)
        // Rollover typing (two fingers, one committing the other).
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        rebuildLayers()
        // The modern (non-deprecated) replacement for overriding
        // `traitCollectionDidChange`: repaint light/dark colors whenever
        // the effective `UITraitUserInterfaceStyle` changes.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: KeyGridView, _: UITraitCollection) in
            view.updateColors()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // Frames (and the accessibility elements derived from them) only
        // need recomputing when the bounds size actually changed, or when
        // `rebuildLayers()` asked for it (a layout/globe change) — every
        // other `layoutSubviews()` pass (e.g. one triggered by a keystroke
        // elsewhere in the extension's view hierarchy) is a no-op here.
        guard needsKeyLayout || bounds.size != lastLaidOutSize else { return }
        performWithoutAnimation {
            layoutKeyLayers()
        }
        lastLaidOutSize = bounds.size
        needsKeyLayout = false
    }

    /// Repaints key labels (text + accessibility labels) without touching
    /// layout — call after anything that can change what a key *shows*
    /// (shift, caps lock). If the press switched `KeyboardState.layer`
    /// (123, #+=, ABC, or the automatic return to letters after a space),
    /// the grid itself is rebuilt for the new layer instead, and every
    /// other touch still down is remapped onto it (see
    /// `remapAfterLayerChange()`) rather than unconditionally cancelled —
    /// a second finger mid-press when a layer switch happens elsewhere
    /// must not simply lose its key.
    public func refreshLabels() {
        guard model.keyboardState.layer == shownLayer else {
            remapAfterLayerChange()
            return
        }
        performWithoutAnimation {
            updateLabelsText()
            updateAccessibilityLabels()
        }
    }

    private var displayScale: CGFloat {
        traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
    }

    /// Runs `body` with implicit Core Animation actions disabled, so any
    /// standalone-`CALayer` property this view touches inside it (frames,
    /// colors, `CATextLayer` strings, added/removed popup layers) changes
    /// instantly instead of animating for 0.25 s — without this, every
    /// highlight and popup visibly lags behind the finger. Safe to nest:
    /// `CATransaction` keeps its own stack.
    private func performWithoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: - Layer construction

    private func rebuildLayers() {
        performWithoutAnimation {
            shownLayer = model.keyboardState.layer
            rows = KeyboardLayout.rows(layoutID, layer: shownLayer, showsGlobe: showsGlobe)
            layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            keyLayers = []
            for row in rows {
                for key in row {
                    let background = CALayer()
                    background.cornerRadius = 5
                    let text = CATextLayer()
                    text.contentsScale = displayScale
                    text.alignmentMode = .center
                    layer.addSublayer(background)
                    background.addSublayer(text)
                    keyLayers.append(KeyLayerInfo(key: key, name: Self.accessibilityName(for: key), background: background, text: text))
                }
            }
            updateColors()
            updateLabelsText()
            // Lay out immediately whenever the view already has a real
            // size, instead of waiting for the next `layoutSubviews()` —
            // a fresh rebuild's frames (and the accessibility elements
            // derived from them) must be correct right away, since
            // `beginPress`'s rollover and `remapAfterLayerChange()` both
            // need to resolve touches against the *current* grid in the
            // very same run-loop turn a rebuild happens in.
            if bounds.width > 0, bounds.height > 0 {
                layoutKeyLayers()
                lastLaidOutSize = bounds.size
                needsKeyLayout = false
            } else {
                needsKeyLayout = true
            }
        }
        setNeedsLayout()
    }

    private func layoutKeyLayers() {
        guard !rows.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
        let rowHeight = bounds.height / CGFloat(rows.count)
        var index = 0
        for (rowIndex, row) in rows.enumerated() {
            let totalUnits = row.reduce(0.0) { $0 + $1.widthUnits }
            guard totalUnits > 0 else {
                index += row.count
                continue
            }
            var x: CGFloat = 0
            let rowY = CGFloat(rowIndex) * rowHeight
            for _ in row {
                let key = keyLayers[index].key
                let width = bounds.width * (key.widthUnits / totalUnits)
                let hitFrame = CGRect(x: x, y: rowY, width: width, height: rowHeight)
                keyLayers[index].frame = hitFrame
                let visualFrame = hitFrame.insetBy(dx: 3, dy: 4)
                keyLayers[index].background.frame = visualFrame
                keyLayers[index].text.frame = CGRect(origin: .zero, size: visualFrame.size)
                x += width
                index += 1
            }
        }
        buildAccessibilityElements()
    }

    // MARK: - Hit testing

    /// The nearest key to `point`: the row whose vertical band contains
    /// `point` (clamped to the first/last row), then within that row the
    /// key whose horizontal center is closest — so a touch between two
    /// keys, or above/below the grid entirely, always resolves to a key
    /// rather than nothing.
    private func nearestKeyIndex(at point: CGPoint) -> Int? {
        guard !rows.isEmpty, bounds.height > 0 else { return nil }
        let rowHeight = bounds.height / CGFloat(rows.count)
        let rawRow = Int(point.y / rowHeight)
        let rowIndex = min(max(rawRow, 0), rows.count - 1)
        var startIndex = 0
        for r in 0..<rowIndex { startIndex += rows[r].count }
        let row = rows[rowIndex]
        guard !row.isEmpty else { return nil }
        var bestIndex = startIndex
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for offset in 0..<row.count {
            let distance = abs(point.x - keyLayers[startIndex + offset].frame.midX)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = startIndex + offset
            }
        }
        return bestIndex
    }

    /// Maps a `Key`'s kind to how `KeyPressTracker` should resolve its
    /// press — see `KeyPressTracker.PressKind`'s doc comment for what
    /// each case means.
    private static func pressKind(for key: Key) -> KeyPressTracker<ObjectIdentifier>.PressKind {
        switch key.kind {
        case .character:
            return .character
        case .shift, .globe, .layerSwitch:
            return .deferred
        case .delete, .space, .returnKey:
            return .immediate
        }
    }

    // MARK: - Touch handling

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        performWithoutAnimation {
            for touch in touches {
                let point = touch.location(in: self)
                let id = ObjectIdentifier(touch)
                touchPoints[id] = point
                beginPress(id: id, at: point, event: event)
            }
        }
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        performWithoutAnimation {
            for touch in touches {
                let point = touch.location(in: self)
                let id = ObjectIdentifier(touch)
                touchPoints[id] = point
                movePress(id: id, to: point, event: event)
            }
        }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        performWithoutAnimation {
            for touch in touches {
                finishPress(id: ObjectIdentifier(touch), event: event, cancelled: false)
            }
        }
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        performWithoutAnimation {
            for touch in touches {
                finishPress(id: ObjectIdentifier(touch), event: event, cancelled: true)
            }
        }
    }

    private func forwardGlobeTouchIfNeeded(id: ObjectIdentifier, event: UIEvent?) {
        guard let index = tracker.currentKeyIndex(for: id), case .globe = keyLayers[index].key.kind, let event else { return }
        onGlobeTouch?(self, event)
    }

    private func beginPress(id: ObjectIdentifier, at point: CGPoint, event: UIEvent?) {
        guard let initialIndex = nearestKeyIndex(at: point) else { return }
        let initialKind = Self.pressKind(for: keyLayers[initialIndex].key)

        // A second touch landing while an earlier character press is
        // still down commits that earlier press right now (rollover
        // typing) — triggered by this touch being `.character` or
        // `.immediate` (space/delete/return), matching the system
        // keyboard. Applying that commit — which may itself rebuild the
        // grid, e.g. space returning to the letters layer — *before*
        // resolving which key this touch lands on keeps `index`/`info`
        // below from ever referring to a stale, pre-rebuild grid.
        if initialKind == .character || initialKind == .immediate, let rollover = tracker.takeRolloverCommit() {
            commit(rollover)
        }

        guard let index = nearestKeyIndex(at: point) else { return }
        let info = keyLayers[index]
        let kind = Self.pressKind(for: info.key)
        tracker.registerTouch(id, at: index, kind: kind)

        var didChangeState = false
        switch info.key.kind {
        case .character:
            // Nothing that affects a label happens at touch-down for a
            // character key — the edit (and any shift/caps change it
            // triggers) only lands at `commit`, so `refreshLabels()` would
            // be pure overhead here.
            showCallout(id: id, for: info)
            if !info.key.alternates.isEmpty {
                startLongPressTimer(id: id, for: index)
            }
        case .delete:
            model.press(info.key, context: buildContext())
            startDeleteRepeat(id: id)
            didChangeState = true
        case .globe:
            // The commit itself (a no-op edit) is deferred to
            // `finishPress`, like shift and the layer keys below — but
            // the touch stream is forwarded live regardless, since
            // `handleInputModeList` needs it to detect its own
            // long-press for the system's input-mode list.
            if let event { onGlobeTouch?(self, event) }
        case .space, .returnKey:
            model.press(info.key, context: buildContext())
            didChangeState = true
        case .shift, .layerSwitch:
            break // Deferred to `finishPress`: committed only if the
                  // finger is still over this key at lift.
        }
        syncHighlights()
        if didChangeState {
            refreshLabels()
        }
    }

    private func movePress(id: ObjectIdentifier, to point: CGPoint, event: UIEvent?) {
        forwardGlobeTouchIfNeeded(id: id, event: event)
        guard let trackedIndex = tracker.currentKeyIndex(for: id) else { return }

        if tracker.isShowingAlternates(for: id) {
            updateSlideSelection(id: id, at: point)
            return
        }
        guard let nearestIndex = nearestKeyIndex(at: point) else { return }

        switch keyLayers[trackedIndex].key.kind {
        case .character:
            guard tracker.moveTouch(id, to: nearestIndex) else { return }
            // Purely visual: move the popup and restart the long-press
            // timer for the new key. No edit happens here — the default
            // character is typed exactly once, at commit (lift).
            hideCallout(id: id)
            longPressTimers[id]?.invalidate()
            longPressTimers[id] = nil
            let newInfo = keyLayers[nearestIndex]
            if case .character = newInfo.key.kind {
                showCallout(id: id, for: newInfo)
                if !newInfo.key.alternates.isEmpty {
                    startLongPressTimer(id: id, for: nearestIndex)
                }
            }
            syncHighlights()
        case .delete:
            // Stop repeating once the finger leaves the delete key;
            // whatever was already deleted stays deleted.
            if nearestIndex != trackedIndex {
                deleteRepeatTimers[id]?.invalidate()
                deleteRepeatTimers[id] = nil
            }
        default:
            // shift/globe/layer keys: never retargeted; just record
            // whether the finger is still over the original key, for
            // `endTouch` to resolve at lift.
            tracker.updateDeferredPresence(id, isOverOriginalKey: nearestIndex == trackedIndex)
        }
    }

    private func finishPress(id: ObjectIdentifier, event: UIEvent?, cancelled: Bool) {
        forwardGlobeTouchIfNeeded(id: id, event: event)
        defer { cleanUpTouch(id) }
        guard let decided = tracker.endTouch(id, cancelled: cancelled) else { return }
        commit(decided)
    }

    /// Applies a decided `Commit`: a selected alternate (if any) instead
    /// of the key's own default output, otherwise the key's regular
    /// `KeyboardModel.press`. The one and only place any of this view's
    /// presses actually produces an edit.
    private func commit(_ decided: KeyPressTracker<ObjectIdentifier>.Commit) {
        guard keyLayers.indices.contains(decided.keyIndex) else { return }
        let info = keyLayers[decided.keyIndex]
        if let alternateIndex = decided.alternateIndex, info.key.alternates.indices.contains(alternateIndex) {
            model.longPressSelect(info.key.alternates[alternateIndex], context: buildContext())
        } else {
            model.press(info.key, context: buildContext())
        }
        refreshLabels()
    }

    /// Tears down whatever UI state (timers, popup, highlight) `id`'s
    /// press was holding, after it has already been resolved (committed
    /// or cancelled) by `tracker.endTouch`.
    private func cleanUpTouch(_ id: ObjectIdentifier) {
        longPressTimers[id]?.invalidate()
        longPressTimers[id] = nil
        deleteRepeatTimers[id]?.invalidate()
        deleteRepeatTimers[id] = nil
        deleteRepeatStarts[id] = nil
        touchPoints[id] = nil
        // `KeyboardState`'s repeat-step counters are shared (ios-17, not
        // per-touch); resetting them once no touch is still repeating
        // delete is the closest sound behavior without redesigning that.
        if deleteRepeatTimers.isEmpty {
            model.resetDeleteRepeat()
        }
        hideCallout(id: id)
        hideAlternates(id: id)
        syncHighlights()
    }

    /// Cancels every in-progress press across every touch — timers,
    /// popups and highlights all torn down, nothing committed. Call when
    /// the keyboard is about to disappear.
    public func cancelActivePress() {
        performWithoutAnimation {
            for timer in longPressTimers.values { timer.invalidate() }
            for timer in deleteRepeatTimers.values { timer.invalidate() }
            longPressTimers.removeAll()
            deleteRepeatTimers.removeAll()
            deleteRepeatStarts.removeAll()
            touchPoints.removeAll()
            model.resetDeleteRepeat()
            for layer in calloutLayers.values { layer.removeFromSuperlayer() }
            for layer in alternatesLayers.values { layer.removeFromSuperlayer() }
            calloutLayers.removeAll()
            alternatesLayers.removeAll()
            tracker.cancelAll()
            syncHighlights()
        }
    }

    /// Called by `refreshLabels()` when a commit changed
    /// `KeyboardState.layer` out from under the currently shown grid
    /// (123, #+=, ABC, or an automatic return to letters) — rebuilds the
    /// grid for the new layer, then remaps every touch still down onto
    /// it instead of just cancelling everything, so a second finger
    /// mid-press doesn't lose its key just because a different finger's
    /// commit happened to change the layer:
    /// - a touch whose point now lands on a `.character` key resumes as
    ///   a fresh character press there (no edit — commits normally at
    ///   its own lift, same as any other character press);
    /// - a held delete whose point still lands on `.delete` keeps
    ///   repeating, retargeted to the new index (its repeat timer/start
    ///   time are left running, untouched);
    /// - anything else still down (a held space/return, or shift/globe/
    ///   layer-switch) simply stops being tracked — nothing to commit for
    ///   those at lift anyway (`.immediate`), or lifting elsewhere than a
    ///   now-meaningless old key position was already how `.deferred`
    ///   cancels.
    private func remapAfterLayerChange() {
        performWithoutAnimation {
            // Every popup/long-press timer is keyed to the old grid's
            // frames/indices, so all of them are torn down regardless of
            // what happens to each touch below — but not the delete-
            // repeat timers: a held delete key must keep repeating across
            // the rebuild for whichever touch keeps tracking it.
            for timer in longPressTimers.values { timer.invalidate() }
            longPressTimers.removeAll()
            for layer in calloutLayers.values { layer.removeFromSuperlayer() }
            calloutLayers.removeAll()
            for layer in alternatesLayers.values { layer.removeFromSuperlayer() }
            alternatesLayers.removeAll()

            // Touches still tracked *before* the rebuild — the ones this
            // remaps; anything already removed from `tracker` (e.g. the
            // very commit that triggered this) is correctly left alone.
            // Each is paired with whether it was a character press on the
            // old grid: only those may resume as a character press below,
            // so a held shift/globe/layer key can never turn into a typed
            // letter just because a letter now sits under that finger.
            let stillTracked: [(id: ObjectIdentifier, oldKind: Key.Kind)] = touchPoints.keys.compactMap { id in
                guard let oldIndex = tracker.currentKeyIndex(for: id), keyLayers.indices.contains(oldIndex) else { return nil }
                return (id, keyLayers[oldIndex].key.kind)
            }

            rebuildLayers()
            // Every key got a brand-new background layer at its default
            // color; any continuing press is re-highlighted below via
            // `syncHighlights()`, which only acts on indices that changed
            // since the last call — so the stale old set must be cleared
            // first, or a still-pressed key would never get re-painted.
            lastHighlightedIndices = []

            for (id, oldKind) in stillTracked {
                let wasCharacter: Bool
                if case .character = oldKind { wasCharacter = true } else { wasCharacter = false }
                guard let point = touchPoints[id], let newIndex = nearestKeyIndex(at: point) else {
                    cancelRemappedTouch(id)
                    continue
                }
                let newInfo = keyLayers[newIndex]
                switch newInfo.key.kind {
                case .character where wasCharacter:
                    tracker.registerTouch(id, at: newIndex, kind: .character)
                    showCallout(id: id, for: newInfo)
                    if !newInfo.key.alternates.isEmpty {
                        startLongPressTimer(id: id, for: newIndex)
                    }
                case .delete where deleteRepeatTimers[id] != nil:
                    tracker.registerTouch(id, at: newIndex, kind: .immediate)
                case .space, .returnKey:
                    // Already committed at touch-down (and possibly the
                    // very press that switched the layer); kept tracked
                    // only so its key stays highlighted until lift.
                    if newInfo.key.kind == oldKind {
                        tracker.registerTouch(id, at: newIndex, kind: .immediate)
                    } else {
                        cancelRemappedTouch(id)
                    }
                default:
                    cancelRemappedTouch(id)
                }
            }
            syncHighlights()
        }
    }

    /// Stops tracking `id`'s press without committing it, and tears down
    /// any delete-repeat timer it was holding — used by
    /// `remapAfterLayerChange()` for a touch whose key no longer makes
    /// sense to keep tracking in the freshly rebuilt grid. The touch
    /// itself isn't necessarily lifted yet; its physical lift later
    /// (`touchesEnded`/`touchesCancelled`) still runs `cleanUpTouch`
    /// harmlessly, since `tracker.endTouch` is a no-op for an already-
    /// untracked id.
    private func cancelRemappedTouch(_ id: ObjectIdentifier) {
        tracker.endTouch(id, cancelled: true)
        deleteRepeatTimers[id]?.invalidate()
        deleteRepeatTimers[id] = nil
        deleteRepeatStarts[id] = nil
        if deleteRepeatTimers.isEmpty {
            model.resetDeleteRepeat()
        }
    }

    /// Block-based (not target/selector) so the timer doesn't retain
    /// `self` strongly — `[weak self]` lets it, and the view, be
    /// deallocated even if something failed to invalidate it. The timer
    /// already fires on the main run loop, so `MainActor.assumeIsolated`
    /// (rather than hopping through `Task { @MainActor in … }`) applies
    /// the tick without an extra async round-trip.
    private func startLongPressTimer(id: ObjectIdentifier, for index: Int) {
        longPressTimers[id]?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.longPressFired(id: id, at: index) }
        }
        RunLoop.main.add(timer, forMode: .common)
        longPressTimers[id] = timer
    }

    private func longPressFired(id: ObjectIdentifier, at index: Int) {
        guard tracker.currentKeyIndex(for: id) == index else { return }
        performWithoutAnimation {
            tracker.showAlternates(for: id)
            showAlternates(id: id, for: keyLayers[index])
        }
    }

    private func startDeleteRepeat(id: ObjectIdentifier) {
        deleteRepeatTimers[id]?.invalidate()
        let start = Date()
        deleteRepeatStarts[id] = start
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.performWithoutAnimation {
                    self.model.deleteRepeatTick(heldFor: Date().timeIntervalSince(start))
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        deleteRepeatTimers[id] = timer
    }

    // MARK: - Highlighting

    /// Diffs `tracker.activeKeyIndices` against the previous call and
    /// toggles only the keys whose pressed state actually changed —
    /// cheap to call after every touch event, and the single place key
    /// highlighting is decided (no other method touches it directly).
    private func syncHighlights() {
        let active = tracker.activeKeyIndices
        guard active != lastHighlightedIndices else { return }
        for index in lastHighlightedIndices.subtracting(active) { highlight(index, pressed: false) }
        for index in active.subtracting(lastHighlightedIndices) { highlight(index, pressed: true) }
        lastHighlightedIndices = active
    }

    private func highlight(_ index: Int, pressed: Bool) {
        guard keyLayers.indices.contains(index) else { return }
        keyLayers[index].background.backgroundColor = pressed
            ? pressedKeyColor.cgColor
            : keyBackgroundColor(for: keyLayers[index].key).cgColor
    }

    // MARK: - Popups

    private func showCallout(id: ObjectIdentifier, for info: KeyLayerInfo) {
        hideCallout(id: id)
        guard case .character = info.key.kind else { return }
        let width = info.frame.width
        let height = info.frame.height * 1.6
        let callout = CALayer()
        callout.backgroundColor = calloutBackgroundColor.cgColor
        callout.cornerRadius = 6
        callout.borderWidth = 0.5
        callout.borderColor = UIColor.separator.cgColor
        callout.frame = CGRect(x: info.frame.midX - width / 2, y: info.frame.minY - height, width: width, height: height)

        let text = CATextLayer()
        text.string = displayText(for: info.key)
        text.alignmentMode = .center
        text.fontSize = fontSize(for: info.key) * 1.3
        text.foregroundColor = keyTextColor.cgColor
        text.contentsScale = displayScale
        text.frame = callout.bounds
        callout.addSublayer(text)

        layer.addSublayer(callout)
        calloutLayers[id] = callout
    }

    private func hideCallout(id: ObjectIdentifier) {
        calloutLayers[id]?.removeFromSuperlayer()
        calloutLayers[id] = nil
    }

    private func showAlternates(id: ObjectIdentifier, for info: KeyLayerInfo) {
        hideCallout(id: id)
        let alternates = info.key.alternates
        guard !alternates.isEmpty else { return }

        let itemWidth = info.frame.width
        let height = info.frame.height * 1.6
        let totalWidth = itemWidth * CGFloat(alternates.count)
        let strip = CALayer()
        strip.backgroundColor = calloutBackgroundColor.cgColor
        strip.cornerRadius = 6
        strip.borderWidth = 0.5
        strip.borderColor = UIColor.separator.cgColor
        strip.frame = CGRect(x: info.frame.midX - totalWidth / 2, y: info.frame.minY - height, width: totalWidth, height: height)

        for (i, alternate) in alternates.enumerated() {
            let text = CATextLayer()
            text.name = "alternate-\(i)"
            text.string = alternate
            text.alignmentMode = .center
            text.fontSize = fontSize(for: info.key) * 1.2
            text.foregroundColor = keyTextColor.cgColor
            text.contentsScale = displayScale
            text.frame = CGRect(x: CGFloat(i) * itemWidth, y: 0, width: itemWidth, height: height)
            strip.addSublayer(text)
        }

        layer.addSublayer(strip)
        alternatesLayers[id] = strip
    }

    private func updateSlideSelection(id: ObjectIdentifier, at point: CGPoint) {
        guard let alternatesLayer = alternatesLayers[id], let keyIndex = tracker.currentKeyIndex(for: id) else { return }
        let info = keyLayers[keyIndex]
        let local = layer.convert(point, to: alternatesLayer)
        guard alternatesLayer.bounds.contains(local), info.frame.width > 0 else {
            setSelectedAlternate(id: id, index: nil)
            return
        }
        let index = max(0, min(info.key.alternates.count - 1, Int(local.x / info.frame.width)))
        setSelectedAlternate(id: id, index: index)
    }

    private func setSelectedAlternate(id: ObjectIdentifier, index: Int?) {
        tracker.selectAlternate(id, index: index)
        guard let alternatesLayer = alternatesLayers[id] else { return }
        for sublayer in alternatesLayer.sublayers ?? [] {
            guard let textLayer = sublayer as? CATextLayer,
                  let name = textLayer.name,
                  let i = Int(name.dropFirst("alternate-".count))
            else { continue }
            textLayer.backgroundColor = (i == index)
                ? UIColor.systemBlue.withAlphaComponent(0.3).cgColor
                : UIColor.clear.cgColor
        }
    }

    private func hideAlternates(id: ObjectIdentifier) {
        alternatesLayers[id]?.removeFromSuperlayer()
        alternatesLayers[id] = nil
    }

    // MARK: - Labels

    /// Re-sets a `CATextLayer`'s `string`/`fontSize` only when the label
    /// actually changed since last time — each real assignment makes
    /// `CATextLayer` re-rasterize its text, so doing this for all ~33 keys
    /// on every keystroke (most of which don't change at all) was the
    /// single biggest per-keystroke cost in this view.
    private func updateLabelsText() {
        for index in keyLayers.indices {
            let newText = displayText(for: keyLayers[index].key)
            guard keyLayers[index].lastDisplayText != newText else { continue }
            keyLayers[index].lastDisplayText = newText
            keyLayers[index].text.string = newText
            keyLayers[index].text.fontSize = fontSize(for: keyLayers[index].key)
        }
    }

    private func displayText(for key: Key) -> String {
        switch key.kind {
        case .character(let base):
            return model.keyboardState.shift != .off ? base.uppercased() : base
        case .shift:
            return model.keyboardState.shift == .locked ? "⇪" : "⇧"
        case .delete:
            return "⌫"
        case .space:
            return "space"
        case .returnKey:
            return returnKeyLabel()
        case .layerSwitch(.letters):
            return "ABC"
        case .layerSwitch(.numbers):
            return "123"
        case .layerSwitch(.symbols):
            return "#+="
        case .globe:
            return "🌐"
        }
    }

    private func fontSize(for key: Key) -> CGFloat {
        switch key.kind {
        case .character: return 20
        case .space, .returnKey: return 15
        default: return 16
        }
    }

    // MARK: - Accessibility

    /// Rebuilds every `UIAccessibilityElement` from scratch — only safe/
    /// worth calling when frames are also being (re)computed, i.e. from
    /// `layoutKeyLayers()`. A label-only change (shift ⇄ caps lock) goes
    /// through `updateAccessibilityLabels()` instead, which mutates the
    /// existing elements in place.
    private func buildAccessibilityElements() {
        var elements: [UIAccessibilityElement] = []
        for info in keyLayers {
            let element = UIAccessibilityElement(accessibilityContainer: self)
            element.accessibilityFrameInContainerSpace = info.frame
            element.accessibilityTraits = .keyboardKey
            element.accessibilityLabel = accessibilityLabel(for: info.key)
            element.accessibilityIdentifier = "keyboard.key.\(info.name)"
            elements.append(element)
        }
        accessibilityElementsList = elements
        accessibilityElements = elements
    }

    /// Updates each existing accessibility element's `accessibilityLabel`
    /// in place — called from `refreshLabels()` so a shift/caps-lock
    /// change doesn't have to reallocate ~33 `UIAccessibilityElement`s the
    /// way rebuilding the whole array on every keystroke would.
    private func updateAccessibilityLabels() {
        guard accessibilityElementsList.count == keyLayers.count else { return }
        for index in keyLayers.indices {
            accessibilityElementsList[index].accessibilityLabel = accessibilityLabel(for: keyLayers[index].key)
        }
    }

    private func accessibilityLabel(for key: Key) -> String {
        switch key.kind {
        case .character(let base):
            return base
        case .shift:
            if model.keyboardState.shift == .locked {
                return String(localized: "keyboard.key.capsLock", defaultValue: "caps lock", bundle: .module)
            }
            return String(localized: "keyboard.key.shift", defaultValue: "shift", bundle: .module)
        case .delete:
            return String(localized: "keyboard.key.delete", defaultValue: "delete", bundle: .module)
        case .space:
            return String(localized: "keyboard.key.space", defaultValue: "space", bundle: .module)
        case .returnKey:
            return returnKeyLabel()
        case .layerSwitch(.letters):
            return String(localized: "keyboard.key.letters", defaultValue: "letters", bundle: .module)
        case .layerSwitch(.numbers):
            return String(localized: "keyboard.key.numbers", defaultValue: "numbers", bundle: .module)
        case .layerSwitch(.symbols):
            return String(localized: "keyboard.key.symbols", defaultValue: "symbols", bundle: .module)
        case .globe:
            return String(localized: "keyboard.key.globe", defaultValue: "next keyboard", bundle: .module)
        }
    }

    private static func accessibilityName(for key: Key) -> String {
        switch key.kind {
        case .character(let base): return base
        case .shift: return "shift"
        case .delete: return "delete"
        case .space: return "space"
        case .returnKey: return "return"
        case .layerSwitch(.letters): return "letters"
        case .layerSwitch(.numbers): return "numbers"
        case .layerSwitch(.symbols): return "symbols"
        case .globe: return "globe"
        }
    }

    // MARK: - Colors

    private func updateColors() {
        performWithoutAnimation {
            backgroundColor = .clear
            for info in keyLayers {
                info.background.backgroundColor = keyBackgroundColor(for: info.key).cgColor
                info.text.foregroundColor = keyTextColor.cgColor
            }
        }
    }

    private var isDark: Bool {
        switch keyboardAppearance {
        case .dark: return true
        case .light: return false
        default: return traitCollection.userInterfaceStyle == .dark
        }
    }

    private func keyBackgroundColor(for key: Key) -> UIColor {
        switch key.kind {
        case .shift, .delete, .layerSwitch, .globe, .returnKey:
            return isDark ? UIColor(white: 0.25, alpha: 1) : UIColor(white: 0.73, alpha: 1)
        default:
            return isDark ? UIColor(white: 0.35, alpha: 1) : .white
        }
    }

    private var keyTextColor: UIColor { isDark ? .white : .black }
    private var pressedKeyColor: UIColor { isDark ? UIColor(white: 0.5, alpha: 1) : UIColor(white: 0.6, alpha: 1) }
    private var calloutBackgroundColor: UIColor { isDark ? UIColor(white: 0.35, alpha: 1) : .white }
}
