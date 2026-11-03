import Foundation
import Network

/// A coarse privacy classification of a provider endpoint's host, derived
/// from the URL alone — DNS is never resolved. Mirrors the desktop's
/// `PrivacyClass` (`src-tauri/src/core/providers/mod.rs`) and adds
/// `.onDevice` for the Apple on-device provider kind, which has no URL at
/// all.
public enum PrivacyClass: String, Codable, Equatable, Sendable {
    case local      // loopback, localhost
    case lan        // private/link-local IPs, .local/.lan/.home/.internal, single-label
    case cloud      // public IPs and domains
    case onDevice   // Apple Foundation Model
}

/// Classifies `baseUrl`'s host. Returns `nil` when the URL (or its host)
/// can't be parsed at all — callers should treat that the same as
/// "unknown" (a request against it will surface `invalidBaseUrl` at call
/// time). Contract fixtures (`contracts/privacy-classification.json`) are
/// the arbiter for every case below.
public func classifyPrivacy(baseUrl: String) -> PrivacyClass? {
    guard let url = URL(string: baseUrl),
          let host = url.host(percentEncoded: false) else {
        return nil
    }
    // IPv4: parse with `IPv4Address` (Network) only to get the raw bytes;
    // the ranges below are hand-rolled to match Rust std's
    // `Ipv4Addr::is_loopback`/`is_private`/`is_link_local` (used by the
    // desktop core), not Network's own `isPrivate`/`isLinkLocal`, which
    // draw slightly different boundaries.
    if let ipv4 = IPv4Address(host) {
        return classifyIPv4(ipv4.rawValue)
    }
    // IPv6: same approach via `IPv6Address`'s raw bytes; `isUniqueLocal`
    // and `isLinkLocal` are not used, to mirror Rust std's
    // `Ipv6Addr::is_loopback` (only `::1`) and its `fc00::/7`/`fe80::/10`
    // ranges exactly. IPv4-mapped IPv6 addresses are not unmapped to IPv4
    // first; they're classified as plain IPv6 (so `::ffff:127.0.0.1` is
    // `.cloud`, not `.local`).
    if let ipv6 = IPv6Address(host) {
        return classifyIPv6(ipv6.rawValue)
    }
    // Domain: classify by suffix and labels.
    let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    if lower == "localhost" || lower.hasSuffix(".localhost") {
        return .local
    }
    if lower.hasSuffix(".local") || lower.hasSuffix(".lan")
        || lower.hasSuffix(".home") || lower.hasSuffix(".internal") {
        return .lan
    }
    if !lower.isEmpty, !lower.contains(".") { // single-label hostnames
        return .lan
    }
    return .cloud
}

/// Classifies `profile`'s endpoint: `.onDevice` for `.appleOnDevice`, `nil`
/// for `.unknown` (an unrecognized provider kind has no meaningful privacy
/// class), else `classifyPrivacy(baseUrl:)`.
public func privacyClass(for profile: ProviderProfile) -> PrivacyClass? {
    switch profile.kind {
    case .appleOnDevice:
        return .onDevice
    case .unknown:
        return nil
    case .openAICompatible:
        return classifyPrivacy(baseUrl: profile.baseUrl)
    }
}

private func classifyIPv4(_ rawValue: Data) -> PrivacyClass {
    let b = [UInt8](rawValue)
    if b[0] == 127 { return .local }                     // 127.0.0.0/8
    if b[0] == 10 { return .lan }                         // 10.0.0.0/8
    if b[0] == 172 && (b[1] & 0xF0) == 16 { return .lan } // 172.16.0.0/12
    if b[0] == 192 && b[1] == 168 { return .lan }         // 192.168.0.0/16
    if b[0] == 169 && b[1] == 254 { return .lan }         // 169.254.0.0/16
    return .cloud
}

private func classifyIPv6(_ rawValue: Data) -> PrivacyClass {
    let b = [UInt8](rawValue)
    if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 {
        return .local                                       // ::1 only
    }
    if (b[0] & 0xFE) == 0xFC { return .lan }                 // fc00::/7
    if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return .lan }  // fe80::/10
    return .cloud
}
