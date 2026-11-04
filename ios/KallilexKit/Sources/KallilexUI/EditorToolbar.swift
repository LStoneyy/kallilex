import SwiftUI

/// Undo / Retry / Copy, enabled according to `EditorSession.canUndo`/
/// `canRetry`/`canCopy` at the call site (ios-08). Kept free of a direct
/// `EditorSession` dependency so it stays trivially previewable/testable
/// with plain booleans.
public struct EditorToolbar: View {
    private let canUndo: Bool
    private let canRetry: Bool
    private let canCopy: Bool
    private let onUndo: () -> Void
    private let onRetry: () -> Void
    private let onCopy: () -> Void

    public init(
        canUndo: Bool,
        canRetry: Bool,
        canCopy: Bool,
        onUndo: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onCopy: @escaping () -> Void
    ) {
        self.canUndo = canUndo
        self.canRetry = canRetry
        self.canCopy = canCopy
        self.onUndo = onUndo
        self.onRetry = onRetry
        self.onCopy = onCopy
    }

    public var body: some View {
        // A vertical fallback at accessibility Dynamic Type sizes (ios-11):
        // three full-length German labels (e.g. "Erneut versuchen") no
        // longer fit one row at AX sizes without truncating.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                undoButton
                retryButton
                copyButton
            }
            VStack(alignment: .leading, spacing: 12) {
                undoButton
                retryButton
                copyButton
            }
        }
    }

    private var undoButton: some View {
        Button(action: onUndo) {
            Label(
                String(localized: "editor.undo", defaultValue: "Undo", bundle: .module),
                systemImage: "arrow.uturn.backward"
            )
        }
        .disabled(!canUndo)
        .accessibilityHint(String(
            localized: "editor.undo.hint",
            defaultValue: "Restores the text from before the last run.",
            bundle: .module
        ))
        .accessibilityIdentifier("editor.undo")
    }

    private var retryButton: some View {
        Button(action: onRetry) {
            Label(
                String(localized: "editor.retry", defaultValue: "Retry", bundle: .module),
                systemImage: "arrow.clockwise"
            )
        }
        .disabled(!canRetry)
        .accessibilityHint(String(
            localized: "editor.retry.hint",
            defaultValue: "Runs the last prompt again.",
            bundle: .module
        ))
        .accessibilityIdentifier("editor.retry")
    }

    private var copyButton: some View {
        Button(action: onCopy) {
            Label(
                String(localized: "editor.copy", defaultValue: "Copy", bundle: .module),
                systemImage: "doc.on.doc"
            )
        }
        .disabled(!canCopy)
        .accessibilityHint(String(
            localized: "editor.copy.hint",
            defaultValue: "Copies the text to the clipboard.",
            bundle: .module
        ))
        .accessibilityIdentifier("editor.copy")
    }
}

#Preview {
    EditorToolbar(
        canUndo: true,
        canRetry: true,
        canCopy: true,
        onUndo: {},
        onRetry: {},
        onCopy: {}
    )
}
