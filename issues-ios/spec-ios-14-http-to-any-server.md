# Spec ios-14 — Plain HTTP to any user-configured server

Status: done
Phase: Phase 5 (Polish)
Depends on: ios-05, ios-12

## Problem Statement

The app only allowed plain `http://` through `NSAllowsLocalNetworking`. That
exception covers `.local` names, unqualified host names and the classic
private address ranges (`10/8`, `172.16/12`, `192.168/16`, link-local). It does
not cover the ways people actually reach a self-hosted AI server from their
phone:

- Tailscale and other CGNAT VPN addresses (`100.64.0.0/10`, e.g.
  `http://100.127.106.115:8017/v1/`), found while testing 1.0.0 on a device.
- Router or VPN host names such as `ai-pc.fritz.box`, `*.home.arpa` or
  `*.ts.net`.
- A home server under the user's own domain without a certificate.

iOS blocks these requests before they leave the device, so the server can't
be used at all. The desktop app allows `http://` to any host; iOS should match.

ATS exceptions can't be scoped to IP ranges, and a list of exception domains
can never cover every VPN, router or personal domain, so a narrower fix isn't
possible.

## Decision

The product owner decided to allow plain HTTP to any server: users who
enter an `http://` URL are responsible for that choice.

- Both `ios/Kallilex/Info.plist` and `ios/ShareExtension/Info.plist` set
  `NSAppTransportSecurity` → `NSAllowsArbitraryLoads = YES`.
- `NSAllowsLocalNetworking` is removed from both. When it is present, iOS
  ignores `NSAllowsArbitraryLoads`, so keeping it would silently undo the
  change.
- `NSLocalNetworkUsageDescription` stays: the Local Network permission is
  separate from ATS and still applies to LAN servers.
- No in-app warning for `http://` URLs. The provider presets keep their
  current URLs (`https://` for OpenAI, `http://…local` for Ollama and
  LM Studio).

This supersedes PLAN.md §10.3 ("Arbitrary loads stay off", "Public `http://`
hosts aren't supported on iOS").

## Implementation

1. Swap the ATS key in both `Info.plist` files as above.
2. CI (`.github/workflows/ios.yml`): extend the bundle checks so the built
   app and extension both have `NSAllowsArbitraryLoads = true` and no
   `NSAllowsLocalNetworking` key. This guards against the key being re-added
   and quietly disabling the setting.
3. App Review (`ios/AppReview/review-notes.md`): add an "App Transport
   Security" section explaining why arbitrary loads are needed. Apple asks
   for a justification when this key is set.
4. PLAN.md §10.3: record the new decision.

## Testing

- CI check from step 2.
- Manual, on a device: add a custom provider with an `http://` URL to a
  Tailscale address, and run Test connection and a prompt from the app and
  from the share sheet.
- Manual: `https://` providers and `.local` LAN servers still work. The Local
  Network prompt still appears the first time a LAN server is used.

## Risks

- A user who types `http://` for a cloud provider sends the API key and text
  unencrypted. Accepted by the product owner; the presets use `https://`.
- App Review may ask about the exception. The justification goes in the
  review notes.

## Out of scope

- Privacy classification of `100.64.0.0/10`. These addresses are still
  classified as `cloud`, so a Tailscale server asks for AI consent and shows
  the cloud badge. Changing that touches the classification contract shared
  with the desktop app (`contracts/privacy-classification.json`) and needs
  its own decision.
