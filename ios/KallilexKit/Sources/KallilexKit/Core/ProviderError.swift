import Foundation

/// The strict error taxonomy surfaced by a `TextProvider`. Mirrors the
/// desktop's `ProviderError` (`src-tauri/src/core/providers/mod.rs`) 1:1 for
/// the first six cases, and adds four iOS-only cases (PLAN.md §7.4) for the
/// on-device model and the Local Network permission. Every case's
/// `errorDescription` is a distinct, actionable message — never a generic
/// "failed" — shown inline by the UI (ios-06, ios-08, ios-09).
public enum ProviderError: Error, Equatable, Sendable {
    case unreachable(String)
    case timeout(Int)
    case http(status: Int, snippet: String)
    case missingModel
    case invalidBaseUrl(String)
    case invalidResponse(String)
    /// The on-device model (or an unsupported provider kind) isn't
    /// available; `reason` is already a complete, actionable sentence
    /// composed by the caller (e.g. `ActionRunner`), not a translation key.
    case unavailable(reason: String)
    case contextTooLong
    /// The on-device model's guardrails rejected the text.
    case declined
    /// The Local Network permission is missing (spike ios-01 unknown 2).
    case localNetworkDenied
}

extension ProviderError {
    /// Stable machine-readable discriminant for frontend matching, mirroring
    /// the desktop's `ProviderError::kind()`.
    public var kind: String {
        switch self {
        case .unreachable: "unreachable"
        case .timeout: "timeout"
        case .http: "http"
        case .missingModel: "missingModel"
        case .invalidBaseUrl: "invalidBaseUrl"
        case .invalidResponse: "invalidResponse"
        case .unavailable: "unavailable"
        case .contextTooLong: "contextTooLong"
        case .declined: "declined"
        case .localNetworkDenied: "localNetworkDenied"
        }
    }
}

extension ProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unreachable(let detail):
            return String(
                localized: "error.unreachable",
                defaultValue: "Can't reach the endpoint — is the server running? (\(detail))",
                bundle: .module
            )
        case .timeout(let secs):
            return String(
                localized: "error.timeout",
                defaultValue: "The request timed out after \(secs) s — the endpoint may be slow or overloaded.",
                bundle: .module
            )
        case .http(let status, let snippet):
            return String(
                localized: "error.http",
                defaultValue: "The server answered HTTP \(status): \(snippet)",
                bundle: .module
            )
        case .missingModel:
            return String(
                localized: "error.missingModel",
                defaultValue: "No model is configured for this profile — set one in Settings.",
                bundle: .module
            )
        case .invalidBaseUrl(let detail):
            return String(
                localized: "error.invalidBaseUrl",
                defaultValue: "The base URL is invalid: \(detail)",
                bundle: .module
            )
        case .invalidResponse(let detail):
            return String(
                localized: "error.invalidResponse",
                defaultValue: "The server sent an unexpected response: \(detail)",
                bundle: .module
            )
        case .unavailable(let reason):
            return String(
                localized: "error.unavailable",
                defaultValue: "\(reason)",
                bundle: .module
            )
        case .contextTooLong:
            return String(
                localized: "error.contextTooLong",
                defaultValue: "The text is too long for this model's context window. Try a shorter selection.",
                bundle: .module
            )
        case .declined:
            return String(
                localized: "error.declined",
                defaultValue: "The on-device model declined to process this text — try different wording or a shorter selection.",
                bundle: .module
            )
        case .localNetworkDenied:
            return String(
                localized: "error.localNetworkDenied",
                defaultValue: "Kallilex isn't allowed to reach your local network. Turn on Local Network for Kallilex in Settings → Privacy & Security → Local Network.",
                bundle: .module
            )
        }
    }
}
