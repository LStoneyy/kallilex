import Foundation

/// UI-free step sequencing for the first-run onboarding flow (ios-07,
/// PLAN.md §4.1). A plain `Sendable` value type rather than an `@Observable`
/// class: the app's `OnboardingView` holds it in a `@State` var and mutates
/// it directly, which SwiftUI already observes for free, and it keeps this
/// type trivially unit-testable from `KallilexKitTests` without any SwiftUI
/// dependency.
///
/// Unlike the original spec sketch (which decided the whole step list up
/// front from the chosen *preset*), the sequence here is decided from the
/// *configured* profile, once it exists: a "Custom" preset's base URL isn't
/// known until the user types it into the provider editor, and it can still
/// turn out to point at a cloud host. `chooseProvider`'s step only picks a
/// starting preset; `providerDetails` is where the profile actually gets
/// filled in (and saved); only once that profile is known does the flow
/// insert (or omit) `.consent`, via `applyConsentRequirement(_:)`.
public struct OnboardingFlow: Equatable, Sendable {
    /// One screen of the onboarding flow. `.consent` carries the host the
    /// consent screen should name — computed by `consentRequirement(for:)`
    /// once the profile is saved, not known at flow-construction time.
    public enum Step: Equatable, Sendable {
        case welcome
        case chooseProvider
        case providerDetails
        case testConnection
        case consent(host: String)
        case shareSheetGuide
        case done
    }

    public private(set) var steps: [Step]
    public private(set) var currentIndex: Int

    public init(steps: [Step], currentIndex: Int = 0) {
        self.steps = steps
        self.currentIndex = min(max(currentIndex, 0), max(steps.count - 1, 0))
    }

    /// The fixed skeleton every onboarding run starts from: welcome, choose
    /// a preset, fill in and save its details, test the connection, learn
    /// the share-sheet guide, and finish. `.consent` is absent until
    /// `applyConsentRequirement(_:)` inserts it.
    public static func initial() -> OnboardingFlow {
        OnboardingFlow(steps: [.welcome, .chooseProvider, .providerDetails, .testConnection, .shareSheetGuide, .done])
    }

    /// The step currently shown. `steps` is never empty (`initial()` always
    /// seeds at least one step, and every mutator below keeps `currentIndex`
    /// in bounds), so this is always defined.
    public var currentStep: Step { steps[currentIndex] }

    /// Moves to the next step, if any. A no-op on the last step (`.done`).
    public mutating func advance() {
        currentIndex = min(currentIndex + 1, steps.count - 1)
    }

    /// Jumps straight to the last step (`.done`) — "Set up later" on any
    /// earlier step. The caller (the app's `OnboardingView`) is responsible
    /// for marking `onboardingCompleted` and dismissing; this type has no
    /// access to `AppSettings`.
    public mutating func skipToEnd() {
        currentIndex = steps.count - 1
    }

    /// "Keep my current provider" on `.chooseProvider` (re-running
    /// onboarding via Settings → "Show setup again" with a provider already
    /// configured): skips `.providerDetails`/`.testConnection`/`.consent`
    /// entirely — no profile is created, edited, or re-tested — straight to
    /// `.shareSheetGuide`. A no-op if `.shareSheetGuide` isn't in `steps`
    /// (it always is, from `initial()`).
    public mutating func keepCurrentProvider() {
        guard let index = steps.firstIndex(of: .shareSheetGuide) else { return }
        currentIndex = index
    }

    /// Returns to `.chooseProvider` — used when the provider editor sheet
    /// presented from `.providerDetails` is dismissed without saving (the
    /// user tapped Cancel rather than Save). A no-op if `.chooseProvider`
    /// isn't in `steps` (it always is, from `initial()`).
    public mutating func returnToChooseProvider() {
        guard let index = steps.firstIndex(of: .chooseProvider) else { return }
        currentIndex = index
    }

    /// Inserts or removes the `.consent` step right after `.testConnection`,
    /// based on `requirement` (from `consentRequirement(for:consents:)`
    /// against the just-saved profile). Idempotent: any existing `.consent`
    /// step is removed first, so calling this again (e.g. after the user
    /// edits the profile again) never duplicates or strands a stale one.
    /// `.granted` and `.notNeeded` both omit the step — a profile the user
    /// already consented to (e.g. re-running onboarding after "Show setup
    /// again") doesn't need to ask again.
    public mutating func applyConsentRequirement(_ requirement: ConsentRequirement) {
        let previousStep = currentIndex < steps.count ? steps[currentIndex] : nil
        steps.removeAll { if case .consent = $0 { return true } else { return false } }
        if case .required(let host) = requirement {
            let insertIndex = steps.firstIndex(of: .testConnection).map { $0 + 1 } ?? steps.count
            steps.insert(.consent(host: host), at: insertIndex)
        }
        // Keep pointing at the same logical step across the mutation above
        // (removing a step before `currentIndex` would otherwise silently
        // shift what's shown).
        if let previousStep, let restored = steps.firstIndex(of: previousStep) {
            currentIndex = restored
        } else {
            currentIndex = min(currentIndex, steps.count - 1)
        }
    }
}
