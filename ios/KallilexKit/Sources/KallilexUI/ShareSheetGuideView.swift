import SwiftUI

/// The five-step guide for pinning Kallilex to the iOS share sheet (ios-07).
/// Shared between the onboarding flow (`shareSheetGuide` step) and the
/// Settings tab's "How to add Kallilex to your share sheet" link — neither
/// owns any navigation chrome (title/Close/Continue); callers wrap it in
/// whatever presentation they need.
///
/// Each step fades and slides in with a short stagger, skipped entirely
/// when `accessibilityReduceMotion` is on (every step appears at once,
/// already in its final position).
///
/// **Open item for a human reviewer:** the exact wording/steps below were
/// not confirmed on a real device during this build (spike ios-01 didn't
/// cover it) — see `issues-ios/spec-ios-07-consent-and-onboarding.md`,
/// "Testing Decisions" / "To confirm".
public struct ShareSheetGuideView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibleStepCount = 0

    private struct Step {
        let symbolName: String
        let text: String
    }

    // Each `String(localized:defaultValue:bundle:)` call needs a literal
    // key, so the five steps are spelled out individually here rather than
    // built from a data table of key strings.
    private var steps: [Step] {
        [
            Step(
                symbolName: "square.and.arrow.up",
                text: String(
                    localized: "shareSheetGuide.step1",
                    defaultValue: "Select text in any app and tap Share.",
                    bundle: .module
                )
            ),
            Step(
                symbolName: "ellipsis.circle",
                text: String(
                    localized: "shareSheetGuide.step2",
                    defaultValue: "Swipe the app row to the end and tap More.",
                    bundle: .module
                )
            ),
            Step(
                symbolName: "pencil",
                text: String(
                    localized: "shareSheetGuide.step3",
                    defaultValue: "Tap Edit.",
                    bundle: .module
                )
            ),
            Step(
                symbolName: "star",
                text: String(
                    localized: "shareSheetGuide.step4",
                    defaultValue: "Add Kallilex to Favorites.",
                    bundle: .module
                )
            ),
            Step(
                symbolName: "arrow.left.to.line.compact",
                text: String(
                    localized: "shareSheetGuide.step5",
                    defaultValue: "Kallilex now appears at the front of the row.",
                    bundle: .module
                )
            ),
        ]
    }

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: step.symbolName)
                            .font(.title2)
                            .frame(width: 32)
                            .foregroundStyle(.tint)
                        Text(step.text)
                            .font(.body)
                            // On the `Text` itself (not the surrounding
                            // `HStack`), so XCUITest finds it as a
                            // `staticTexts` element rather than `otherElements`.
                            .accessibilityIdentifier("shareSheetGuide.step\(index + 1)")
                        Spacer(minLength: 0)
                    }
                    .opacity(visibleStepCount > index ? 1 : 0)
                    .offset(y: visibleStepCount > index || reduceMotion ? 0 : 12)
                }
            }
            .padding()
        }
        // `.task`, not `.onAppear` + `DispatchQueue.asyncAfter`: SwiftUI
        // cancels a `.task` automatically when the view disappears, so a
        // dismissal mid-stagger (e.g. tapping Continue right away) never
        // leaves a dangling timer trying to mutate `visibleStepCount` on a
        // torn-down view.
        .task {
            await animateStepsIn()
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
    ShareSheetGuideView()
}
