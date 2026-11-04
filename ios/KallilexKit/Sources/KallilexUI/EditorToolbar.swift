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
        HStack(spacing: 12) {
            Button(action: onUndo) {
                Label(
                    String(localized: "editor.undo", defaultValue: "Undo", bundle: .module),
                    systemImage: "arrow.uturn.backward"
                )
            }
            .disabled(!canUndo)
            .accessibilityIdentifier("editor.undo")

            Button(action: onRetry) {
                Label(
                    String(localized: "editor.retry", defaultValue: "Retry", bundle: .module),
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(!canRetry)
            .accessibilityIdentifier("editor.retry")

            Button(action: onCopy) {
                Label(
                    String(localized: "editor.copy", defaultValue: "Copy", bundle: .module),
                    systemImage: "doc.on.doc"
                )
            }
            .disabled(!canCopy)
            .accessibilityIdentifier("editor.copy")
        }
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
