# wraith-ios — Agent Instructions

## Project Purpose

WireGuard-based VPN iOS client for the Katafract Enclave platform (branded Veil / WraithGate). Provides one-tap VPN connection, Haven DNS protection, server selection, and StoreKit 2 subscription management. Connects to `api.katafract.com` for token validation, peer provisioning, and DNS preferences.

## Tech Stack

- **Language**: Swift / SwiftUI
- **Platform**: iOS (+ macOS Catalyst via `WraithVPNMac`)
- **VPN**: WireGuardKit 1.0.15-26+ (Network Extension — out-of-process tunnel)
- **Payments**: StoreKit 2
- **CI/CD**: Xcode Cloud (automated deploy to TestFlight on tag push)
- **Build script**: `./scripts/bump` — auto-increments build, tags, pushes → triggers Xcode Cloud

## Targets

| Target | Bundle ID | Purpose |
|---|---|---|
| WraithVPN | `com.katafract.wraith` | Main iOS app |
| WireGuardTunnel | `com.katafract.wraith.tunnel` | NEPacketTunnelProvider (out-of-process) |
| WraithVPNMac | (Catalyst) | macOS variant |

**Development Team**: `2SGGP65W6C`

## Key Files

| File | Purpose |
|---|---|
| `WraithVPN/APIClient.swift` | Backend API calls to `api.katafract.com` |
| `WraithVPN/WireGuardManager.swift` | VPN tunnel lifecycle (connect/disconnect/status) |
| `WraithVPN/StoreKitManager.swift` | Subscription purchases and validation |
| `WraithVPN/ServerListManager.swift` | WraithGate node list and selection |
| `WraithVPN/HavenDNSManager.swift` | Haven DNS preference management |
| `WireGuardTunnel/` | NEPacketTunnelProvider implementation |
| `scripts/bump` | Increment build number, tag, push → triggers Xcode Cloud |
| `TestPlan.xctestplan` | Xcode test plan configuration |

## Backend API Endpoints (`https://api.katafract.com`)

- Token validation
- Peer provisioning (WireGuard config delivery)
- Server list
- DNS preferences
- Subscription status

## How to Build

```bash
xcodebuild -scheme WraithVPN -destination 'platform=iOS Simulator,name=iPhone 16' build
```

To release to TestFlight:
```bash
./scripts/bump   # increments build, tags, pushes — Xcode Cloud takes over
```

## How to Run Tests

```bash
xcodebuild test -scheme WraithVPN -testPlan TestPlan -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Architectural Constraints

- **Process separation**: main app and tunnel are separate processes — communicate via App Groups and Keychain sharing only
- **Entitlements**: Network Extension, Keychain sharing, App Groups — do not modify carelessly; VPN silently fails without correct entitlements
- **WireGuardKit** linked to tunnel target only — do not import in main app target
- **Bundle IDs** are tied to App Store Connect, Apple Developer Portal, and provisioning profiles — do not change without updating all three

## Critical Files — Do NOT Change Without Full Understanding

- `*.entitlements` files — VPN will break
- `Info.plist` for both targets — extension type must remain `com.apple.networkextension.packet-tunnel`
- `Package.swift` / SPM dependency on WireGuardKit — version must remain compatible with Apple's NEPacketTunnelProvider API
- App Group identifiers — shared between main app and tunnel for IPC

## Constraints

- Do not add VPN logic to the main app target — all tunnel code belongs in `WireGuardTunnel/`
- Do not replace WireGuardKit with a third-party WireGuard implementation
- Do not store the WireGuard private key outside of the iOS Keychain
- Subscription validation must go through `api.katafract.com` — do not validate receipts client-side only
- macOS Catalyst variant shares ~95% of iOS code — changes in shared files affect both platforms
