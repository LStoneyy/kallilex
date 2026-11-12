import SwiftUI
import UIKit

/// Teaches adding the Kallilex Keyboard in iOS Settings and explains Full
/// Access honestly before Apple's own system warning appears (ios-22,
/// PLAN-keyboard.md §4.1) — shown both as an onboarding step and from
/// Settings → Keyboard → "How to add the keyboard". Modeled on
/// `ShareSheetGuideView`: the three illustration steps fade/slide in with
/// the same short stagger (skipped entirely when `accessibilityReduceMotion`
/// is on), and this view owns no navigation chrome either (no title/Close);
/// callers wrap it in whatever presentation they need.
///
/// Deliberately never mentions dictation anywhere (deferred, D10 in
/// PLAN-keyboard.md) and never detects Full Access or the added keyboard
/// itself from the app — there is no public API for either (spike ios-01,
/// unknown 12 found only a private KVC key, which must not ship).
public struct KeyboardGuideView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var visibleStepCount = 0

    private struct Step {
        let symbolName: String
        let text: String
        let identifier: String
    }

    // Each `String(localized:defaultValue:)` call needs a literal key, so
    // the three steps are spelled out individually here rather than built
    // from a data table of key strings (mirrors `ShareSheetGuideView`).
    private var steps: [Step] {
        [
            Step(
                symbolName: "gearshape",
                text: String(
                    localized: "keyboard.guide.step1",
                    defaultValue: "Open Settings → General → Keyboard.",
                    bundle: .module
                ),
                identifier: "keyboard.guide.step1"
            ),
            Step(
                symbolName: "keyboard",
                text: String(
                    localized: "keyboard.guide.step2",
                    defaultValue: "Tap Keyboards → Add New Keyboard.",
                    bundle: .module
                ),
                identifier: "keyboard.guide.step2"
            ),
            Step(
                symbolName: "plus.circle",
                text: String(
                    localized: "keyboard.guide.step3",
                    defaultValue: "Tap Kallilex to add it.",
                    bundle: .module
                ),
                identifier: "keyboard.guide.step3"
            ),
        ]
    }

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: step.symbolName)
                                .font(.title2)
                                .frame(width: 32)
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                            Text(step.text)
                                .font(.body)
                                // On the `Text` itself (not the surrounding
                                // `HStack`), same reasoning as
                                // `ShareSheetGuideView`: XCUITest then finds
                                // it as a `staticTexts` element.
                                .accessibilityIdentifier(step.identifier)
                            Spacer(minLength: 0)
                        }
                        .opacity(visibleStepCount > index ? 1 : 0)
                        .offset(y: visibleStepCount > index || reduceMotion ? 0 : 12)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 16) {
                    Text(String(
                        localized: "keyboard.guide.fullAccess.title",
                        defaultValue: "Allow Full Access",
                        bundle: .module
                    ))
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("keyboard.guide.fullAccess.title")

                    fullAccessRow(
                        label: String(
                            localized: "keyboard.guide.fullAccess.why.label",
                            defaultValue: "Why",
                            bundle: .module
                        ),
                        text: String(
                            localized: "keyboard.guide.fullAccess.why",
                            defaultValue: "Full Access lets the keyboard send the Scratchpad text to your AI provider and copy results.",
                            bundle: .module
                        ),
                        identifier: "keyboard.guide.fullAccess.why"
                    )

                    fullAccessRow(
                        label: String(
                            localized: "keyboard.guide.fullAccess.never.label",
                            defaultValue: "Never",
                            bundle: .module
                        ),
                        text: String(
                            localized: "keyboard.guide.fullAccess.never",
                            defaultValue: "Kallilex never records or sends what you type. Only the Scratchpad text goes to your provider, when you tap a prompt.",
                            bundle: .module
                        ),
                        identifier: "keyboard.guide.fullAccess.never"
                    )

                    fullAccessRow(
                        label: String(
                            localized: "keyboard.guide.fullAccess.withoutIt.label",
                            defaultValue: "Without it",
                            bundle: .module
                        ),
                        text: String(
                            localized: "keyboard.guide.fullAccess.withoutIt",
                            defaultValue: "Typing and Insert work without Full Access.",
                            bundle: .module
                        ),
                        identifier: "keyboard.guide.fullAccess.withoutIt"
                    )
                }

                // Opens the app's own Settings page via SwiftUI's
                // `openURL`, never `UIApplication.shared` (unavailable to
                // extensions — `KallilexUI` is also linked by the Share
                // Extension) and never the private `App-prefs:` scheme.
                // `UIApplication.openSettingsURLString` is a plain string
                // constant, not an instance call, so it's safe here.
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Text(String(
                        localized: "keyboard.guide.openSettings",
                        defaultValue: "Open Settings",
                        bundle: .module
                    ))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("keyboard.guide.openSettings")

                Text(String(
                    localized: "keyboard.guide.note",
                    defaultValue: "iOS will warn that the keyboard can transmit what you type. This is the standard warning for every keyboard with Full Access.",
                    bundle: .module
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("keyboard.guide.note")
            }
            .padding()
        }
        .accessibilityIdentifier("keyboard.guide")
        // Same reasoning as `ShareSheetGuideView`: `.task`, not `.onAppear`
        // + `DispatchQueue.asyncAfter`, so a dismissal mid-stagger never
        // leaves a dangling timer mutating a torn-down view's state.
        .task {
            await animateStepsIn()
        }
    }

    private func fullAccessRow(label: String, text: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.subheadline.weight(.semibold))
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
        }
    }

    private func animateStepsIn() async {
        guard !reduceMotion else {
            visibleStepCount = steps.count
            return
        }
        guard visibleStepCount == 0 else { return }
        for index in steps.indices {
            if index > 0 {
                try? await Task.sleep(for: .seconds(0.15))
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                visibleStepCount = index + 1
            }
        }
    }
}

#Preview {
    KeyboardGuideView()
}
