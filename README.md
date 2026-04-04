# WraithVPN — iOS & macOS Client

Privacy-focused WireGuard VPN client. Targets iOS 17+ and macOS 14+ (Mac Catalyst).

---

## Opening in Xcode

```
open WraithVPN.xcodeproj
```

Requires Xcode 15.4 or later.

---

## Project structure

```
WraithVPN/
├── WraithVPN.xcodeproj/           Xcode project (two targets)
│
├── WraithVPN/                     Main app target
│   ├── WraithVPNApp.swift         @main entry point; creates ObservableObject singletons
│   ├── Models/
│   │   └── Models.swift           All Codable API models + VPNStatus + SubscriptionInfo
│   ├── Managers/
│   │   ├── APIClient.swift        Typed async/await HTTP client (all endpoints)
│   │   ├── WireGuardManager.swift Keypair gen, peer provisioning, NetworkExtension toggle
│   │   ├── StoreKitManager.swift  StoreKit 2 purchase + token exchange flow
│   │   └── ServerListManager.swift Server list fetch + concurrent TCP latency probes
│   ├── Helpers/
│   │   ├── KeychainHelper.swift   Generic Keychain wrapper (token, private key)
│   │   └── DesignSystem.swift     Colours, gradients, typography scale, spacing tokens
│   ├── Views/
│   │   ├── ContentView.swift      Root: onboarding gate → paywall gate → main app
│   │   ├── OnboardingView.swift   3-screen carousel (first launch)
│   │   ├── ConnectView.swift      Main screen: animated ring button, status, server picker
│   │   ├── ServerPickerView.swift Server list, latency badges, load bars, search/sort
│   │   ├── SettingsView.swift     Plan info, expiry, manage subscription, sign out
│   │   └── PaywallView.swift      StoreKit 2 paywall: monthly vs annual, feature list
│   ├── Assets.xcassets/           App icon + accent colour stubs
│   ├── Info.plist
│   └── WraithVPN.entitlements
│
└── WireGuardTunnel/               Network Extension target (out-of-process tunnel)
    ├── PacketTunnelProvider.swift  NEPacketTunnelProvider subclass (WireGuardKit stub)
    ├── Info.plist                  NSExtension / NSExtensionPrincipalClass declaration
    └── WireGuardTunnel.entitlements
```

---

## Required Apple entitlements

Both the App Store Connect record and your local provisioning profile must have:

| Entitlement | Main app | Tunnel ext |
|---|---|---|
| `com.apple.developer.networking.networkextension` → `packet-tunnel-provider` | yes | yes |
| `com.apple.developer.in-app-payments` (product IDs listed) | yes | no |
| `keychain-access-groups` → `com.katafract.wraith` & `.tunnel` | yes | yes |
| `com.apple.security.application-groups` → `group.com.katafract.wraith` | yes | yes |

### How to configure

1. Log into [developer.apple.com](https://developer.apple.com/account).
2. Under **Certificates, IDs & Profiles → Identifiers**, register:
   - `com.katafract.wraith` — enable *Network Extensions*, *In-App Purchase*, *App Groups*, *Keychain Sharing*
   - `com.katafract.wraith.tunnel` — enable *Network Extensions*, *App Groups*, *Keychain Sharing*
3. Create an App Group ID: `group.com.katafract.wraith`
4. Add your Team ID to the empty `DEVELOPMENT_TEAM = ""` lines in `project.pbxproj`.
5. Xcode will auto-manage signing from there.

---

## WireGuardKit dependency

The tunnel extension requires the official WireGuard Swift library:

1. In Xcode: **File → Add Package Dependencies**
2. URL: `https://github.com/WireGuard/wireguard-apple`
3. Select **WireGuardKit** and add it to the **WireGuardTunnel** target only.
4. In `WireGuardTunnel/PacketTunnelProvider.swift`, uncomment the `import WireGuardKit` line and the adapter block inside `startTunnel`.

---

## App Store products

Register these product IDs in App Store Connect under the app's In-App Purchases:

| Product ID | Type | Price |
|---|---|---|
| `com.katafract.wraith_armor_monthly` | Auto-Renewable Subscription | $4.99/mo |
| `com.katafract.wraith_armor_annual`  | Auto-Renewable Subscription | $39.99/yr |

Both belong to the same Subscription Group so users can upgrade/downgrade between them.

---

## First-run flow

```
Launch
  └─ hasSeenOnboarding == false → OnboardingView (3 screens)
       └─ "Get Started" → hasSeenOnboarding = true
            └─ hasPurchased == false → PaywallView
                 └─ Purchase → StoreKitManager → /v1/token/validate/apple
                      └─ token stored in Keychain
                           └─ ContentView renders MainApp (ConnectView)

Connect (first time)
  └─ WireGuardManager.connectToServer(_:)
       1. ensureKeypair() — CryptoKit Curve25519, stored in Keychain
       2. APIClient.provisionPeer(pubkey:region:label:) → ProvisionResponse
       3. installProfile(configText:server:) — NETunnelProviderManager
       4. startTunnel() → NETunnelProviderSession.startTunnel(options:)
       5. PacketTunnelProvider (out-of-process) receives config, starts WireGuard

Connect (subsequent)
  └─ WireGuardManager.connect() — just calls startTunnel() on existing profile
```

---

## Bundle ID

`com.katafract.wraith` — change this in `project.pbxproj` (`PRODUCT_BUNDLE_IDENTIFIER`) and `Info.plist` if you use a different Apple Developer account.

---

## macOS support

Mac Catalyst is enabled (`SUPPORTS_MACCATALYST = YES`). The app compiles and runs on macOS via Catalyst with no code changes. For a native macOS target (SwiftUI lifecycle), create a second app target with `SDKROOT = macosx` and the same source files — no UIKit-specific APIs are used except for `UIImpactFeedbackGenerator` (guarded with `#if canImport(UIKit)`).

---

## Backend API

Base URL: `https://api.katafract.com`

All authenticated endpoints require `Authorization: Bearer <token>` where `<token>` is the plaintext token returned by `/v1/token/validate/apple` after a successful StoreKit 2 purchase. The token is stored in Keychain under `com.katafract.wraith.subscriptionToken`.
