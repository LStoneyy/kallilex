import Foundation

/// Whether a profile needs the user's explicit consent before text is sent
/// to it (PLAN.md §10.1), and if so, whether that consent has already been
/// granted. Shared by `ActionRunner` (which only cares about `.required` vs.
/// everything else) and the onboarding flow / `ConsentView` (ios-07, which
/// also distinguish `.granted` to decide whether to show the consent step at
/// all).
public enum ConsentRequirement: Equatable, Sendable {
    /// `profile`'s kind/privacy class never requires consent (on-device,
    /// local, LAN, or an unrecognized `kind`).
    case notNeeded
    /// `profile` is a cloud `.openAICompatible` endpoint and no consent is
    /// on file for its current host.
    case required(host: String)
    /// `profile` is a cloud `.openAICompatible` endpoint and consent for its
    /// current host is already on file.
    case granted
}

/// Computes `profile`'s consent requirement against `consents` — the same
/// predicate `ActionRunner.run` uses to decide whether to return
/// `.consentRequired`, factored out here so the onboarding flow (ios-07) and
/// `SettingsService`'s callers never have to re-derive it by hand.
///
/// Only `.openAICompatible` profiles whose `classifyPrivacy(baseUrl:)` is
/// `.cloud` ever need consent — `.appleOnDevice`, `.unknown`, `.local`, and
/// `.lan` always return `.notNeeded`, mirroring `ActionRunner`'s own check.
/// A cloud profile whose `baseUrl` doesn't parse into a host at all can't
/// actually happen here: `classifyPrivacy(baseUrl:)` only ever returns
/// `.cloud` for a URL that *does* have a host, and `consentHost(for:)` parses
/// the same URL the same way — so `consentHost(for:)` returning `nil` in that
/// branch is unreachable in practice; this function treats that case as
/// `.notNeeded` rather than asserting, since there is no host to require
/// consent for.
public func consentRequirement(for profile: ProviderProfile, consents: [AIConsent]) -> ConsentRequirement {
    guard profile.kind == .openAICompatible,
          classifyPrivacy(baseUrl: profile.baseUrl) == .cloud,
          let host = consentHost(for: profile) else {
        return .notNeeded
    }
    let granted = consents.contains { $0.profileID == profile.id && $0.host == host }
    return granted ? .granted : .required(host: host)
}
