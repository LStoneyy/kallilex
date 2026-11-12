import SwiftUI
import KallilexKit

/// A row of tappable prompt chips, plus a trailing "Custom…" chip, shared by
/// the Scratchpad tab and the Share Extension (ios-08). Horizontally
/// scrollable at ordinary Dynamic Type sizes; switches to a vertical list of
/// full-width buttons from `.accessibility3` up (ios-11), since a capsule
/// row stops being usable once each label wraps to multiple lines. Grouped
/// as a single accessibility container ("Prompts") so VoiceOver's rotor
/// presents the chips as one logical group of children, rather than a flat
/// run of unrelated buttons (ios-11, "Hierarchy and grouping"). Long-pressing
/// a chip shows its full instruction via `contextMenu`. Every chip is
/// disabled while `isRunning` — starting a second run from a chip mid-run
/// would just be superseded anyway (`EditorSession.run` cancels the
/// in-flight one), so disabling avoids a confusing extra tap.
public struct PromptChipsBar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let prompts: [CustomPrompt]
    private let isRunning: Bool
    private let onSelectPrompt: (CustomPrompt) -> Void
    /// `nil` hides the "Custom…" chip (the keyboard has no custom
    /// instruction in v1).
    private let onCustomTapped: (() -> Void)?
    /// `true` keeps this a single horizontally scrolling row with a fixed
    /// height at every Dynamic Type size, never switching to the vertical
    /// list below — the keyboard's own fixed-height chips row (ios-23
    /// spec, "Dynamic Type": "the keyboard's height can't grow, so the
    /// vertical chip stacking from ios-11 doesn't apply here"). The app
    /// and Share Extension keep the default `false` (ios-11 behavior).
    private let forcesSingleRow: Bool

    public init(
        prompts: [CustomPrompt],
        isRunning: Bool,
        onSelectPrompt: @escaping (CustomPrompt) -> Void,
        onCustomTapped: (() -> Void)?,
        forcesSingleRow: Bool = false
    ) {
        self.prompts = prompts
        self.isRunning = isRunning
        self.onSelectPrompt = onSelectPrompt
        self.onCustomTapped = onCustomTapped
        self.forcesSingleRow = forcesSingleRow
    }

    public var body: some View {
        Group {
            if dynamicTypeSize >= .accessibility3, !forcesSingleRow {
                VStack(alignment: .leading, spacing: 8) {
                    chips
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chips
                    }
                    .padding(.horizontal)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "promptChipsBar.label", defaultValue: "Prompts", bundle: .module))
    }

    @ViewBuilder
    private var chips: some View {
        ForEach(prompts) { prompt in
            PromptChip(
                label: prompt.label,
                instruction: prompt.instruction,
                isDisabled: isRunning,
                onTap: { onSelectPrompt(prompt) }
            )
            .accessibilityIdentifier("editor.chip.\(prompt.id)")
        }

        if let onCustomTapped {
            Button(action: onCustomTapped) {
                Label(
                    String(localized: "prompt.custom", defaultValue: "Custom…", bundle: .module),
                    systemImage: "square.and.pencil"
                )
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(isRunning)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityHint(String(
                localized: "prompt.custom.hint",
                defaultValue: "Opens a field for your own instruction.",
                bundle: .module
            ))
            .accessibilityIdentifier("editor.chip.custom")
        }
    }
}

private struct PromptChip: View {
    let label: String
    let instruction: String
    let isDisabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(label)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .disabled(isDisabled)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityHint(String(
            localized: "editor.chip.hint",
            defaultValue: "Runs this prompt on the text.",
            bundle: .module
        ))
        .contextMenu {
            Text(instruction)
        }
    }
}

#Preview {
    PromptChipsBar(
        prompts: [
            CustomPrompt(id: "1", label: "Fix grammar", instruction: "Fix grammar and spelling."),
            CustomPrompt(id: "2", label: "Shorten", instruction: "Make this more concise."),
        ],
        isRunning: false,
        onSelectPrompt: { _ in },
        onCustomTapped: {}
    )
}
