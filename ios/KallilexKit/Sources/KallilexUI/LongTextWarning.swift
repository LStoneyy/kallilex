import SwiftUI

/// A non-blocking warning shown when `EditorSession.isTextLong` is `true`
/// (PLAN.md §8.3): the text may be slow or exceed the model's context
/// window. Never prevents a run — only ios-10's on-device hard limit does
/// that.
public struct LongTextWarning: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(String(
                localized: "editor.textTooLong",
                defaultValue: "Long texts can be slow or exceed the model's limit.",
                bundle: .module
            ))
        }
        .font(.caption)
        .padding(8)
        .background(Color.orange.opacity(0.1))
        .accessibilityIdentifier("editor.textTooLong")
    }
}

#Preview {
    LongTextWarning()
}
