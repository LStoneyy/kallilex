import SwiftUI
import KallilexKit

/// Prompt mode's compact editor toolbar (ios-18 spec, "A compact keyboard
/// toolbar"): an icon-only horizontal row — Undo, Retry, Copy, and (once a
/// result exists) Show original — at `KeyboardPromptMetrics.toolbarHeight`
/// (32 pt). A keyboard-only view rather than a `compact` style on
/// `EditorToolbar` itself, since it reuses that view's existing
/// identifiers/strings (`editor.undo`/`editor.retry`/`editor.copy`,
/// `editor.showOriginal`) without touching the app's own (unchanged)
/// layout. Every button's hit area is at least 44×32 via an explicit
/// `.frame` plus `contentShape`, even though the row itself is only 32 pt
/// tall — found necessary by this file's own accessibility audit (the
/// previous full `EditorToolbar`, stacked vertically inside a fixed 32 pt
/// row, overflowed and wasn't hit-testable at all).
public struct KeyboardCompactToolbar: View {
    private let canUndo: Bool
    private let canRetry: Bool
    private let canCopy: Bool
    private let showsShowOriginal: Bool
    private let isShowingOriginal: Bool
    private let onUndo: () -> Void
    private let onRetry: () -> Void
    private let onCopy: () -> Void
    private let onToggleShowOriginal: () -> Void

    public init(
        canUndo: Bool,
        canRetry: Bool,
        canCopy: Bool,
        showsShowOriginal: Bool,
        isShowingOriginal: Bool,
        onUndo: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onToggleShowOriginal: @escaping () -> Void
    ) {
        self.canUndo = canUndo
        self.canRetry = canRetry
        self.canCopy = canCopy
        self.showsShowOriginal = showsShowOriginal
        self.isShowingOriginal = isShowingOriginal
        self.onUndo = onUndo
        self.onRetry = onRetry
        self.onCopy = onCopy
        self.onToggleShowOriginal = onToggleShowOriginal
    }

    public var body: some View {
        HStack(spacing: 20) {
            button(
                systemImage: "arrow.uturn.backward",
                label: String(localized: "editor.undo", defaultValue: "Undo", bundle: .module),
                hint: String(
                    localized: "editor.undo.hint",
                    defaultValue: "Restores the text from before the last run.",
                    bundle: .module
                ),
                identifier: "editor.undo",
                isDisabled: !canUndo,
                action: onUndo
            )
            button(
                systemImage: "arrow.clockwise",
                label: String(localized: "editor.retry", defaultValue: "Retry", bundle: .module),
                hint: String(
                    localized: "editor.retry.hint",
                    defaultValue: "Runs the last prompt again.",
                    bundle: .module
                ),
                identifier: "editor.retry",
                isDisabled: !canRetry,
                action: onRetry
            )
            button(
                systemImage: "doc.on.doc",
                label: String(localized: "editor.copy", defaultValue: "Copy", bundle: .module),
                hint: String(
                    localized: "editor.copy.hint",
                    defaultValue: "Copies the text to the clipboard.",
                    bundle: .module
                ),
                identifier: "editor.copy",
                isDisabled: !canCopy,
                action: onCopy
            )
            if showsShowOriginal {
                button(
                    systemImage: isShowingOriginal ? "eye.slash" : "eye",
                    label: String(localized: "editor.showOriginal", defaultValue: "Show original", bundle: .module),
                    hint: String(
                        localized: "editor.showOriginal.hint",
                        defaultValue: "Shows the text from before the last run.",
                        bundle: .module
                    ),
                    identifier: "editor.showOriginal",
                    isDisabled: false,
                    action: onToggleShowOriginal
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: KeyboardPromptMetrics.toolbarHeight)
    }

    private func button(
        systemImage: String,
        label: String,
        hint: String,
        identifier: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .disabled(isDisabled)
        .frame(minWidth: 44, minHeight: KeyboardPromptMetrics.toolbarHeight)
        .contentShape(Rectangle())
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityIdentifier(identifier)
    }
}

#Preview {
    KeyboardCompactToolbar(
        canUndo: true,
        canRetry: true,
        canCopy: true,
        showsShowOriginal: true,
        isShowingOriginal: false,
        onUndo: {},
        onRetry: {},
        onCopy: {},
        onToggleShowOriginal: {}
    )
}
